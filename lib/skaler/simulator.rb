# Discrete-event queue simulator for autoscaler tuning.
#
# Models individual job arrivals, completions, and cascading at sub-second
# granularity. Uses the pluggable control-loop architecture (Sensors → MetricStore →
# Controller → Actuator) via `Skaler::Loop`.
#
# @example
#   types = {
#     process_email: Skaler::JobType.new(
#       name: :process_email,
#       duration: ->(rng) { rng.rand(0.5..3.0) },
#       spawn_rules: [{ probability: 0.8, child_type: :summarize, count: 1 }]
#     ),
#     summarize: Skaler::JobType.new(
#       name: :summarize,
#       duration: ->(rng) { rng.rand(3.0..15.0) },
#       spawn_rules: []
#     )
#   }
#
#   sim = Skaler::Simulator.new(
#     job_types: types,
#     arrival_process: { mode: :poisson, rate_per_minute: 730, default_type: :process_email },
#     pid_config: { kp: 0.8, ki: 0.1, kd: 0.35, setpoint: 0.7, deadband: 0.1 },
#     pool_config: { initial_workers: 2, threads_per_worker: 5, min_workers: 2, max_workers: 60 },
#     constraints: { pg_max: 2000, redis_max: 5000, pg_pool_size: 7, redis_pool_per_worker: 10 },
#     timing: { autoscaler_interval: 60, boot_lag_seconds: 120, cooldown_seconds: 15, max_time: 7200 },
#     random_seed: 42
#   )
#   trace = sim.run
class Skaler::Simulator
  # @param job_types [Hash{Symbol => Skaler::JobType}] job type definitions
  # @param arrival_process [Hash, Skaler::ArrivalProcess] arrival process config or instance
  # @param pid_config [Hash] PID tuning: kp, ki, kd, deadband, setpoint
  # @param pool_config [Hash] initial_workers, threads_per_worker, min_workers, max_workers
  # @param constraints [Hash] pg_max, redis_max, pg_pool_size, redis_pool_per_worker
  # @param timing [Hash] autoscaler_interval, boot_lag_seconds, cooldown_seconds, max_time
  # @param smoothing_alpha [Float] EMA factor (default 0.15)
  # @param metric_mode [String] "utilization" or "pressure"
  # @param random_seed [Integer] for deterministic replay
  # @param progress_reporter [Skaler::ProgressReporter, nil] optional progress reporter
  def initialize(
    job_types:,
    arrival_process:,
    pid_config:,
    pool_config:,
    constraints:,
    timing:,
    smoothing_alpha: 0.15,
    metric_mode: "utilization",
    random_seed: 42,
    progress_reporter: nil
  )
    @job_types = job_types
    @arrival_process_config = arrival_process
    @pid_config = pid_config
    @pool_config = pool_config
    @constraints = constraints
    @timing = timing
    @smoothing_alpha = smoothing_alpha
    @metric_mode = metric_mode
    @random_seed = random_seed
    @progress_reporter = progress_reporter
  end

  # Run the simulation and return trace snapshots.
  #
  # @return [Array<Hash>] one snapshot per autoscaler tick
  def run
    @rng = Random.new(@random_seed)
    @queue = Skaler::EventQueue.new
    @pool = Skaler::WorkerPool.new(
      worker_count: @pool_config[:initial_workers],
      threads_per_worker: @pool_config[:threads_per_worker]
    )
    @trace = Skaler::Trace.new
    @ready_queue = []
    @cumulative_instance_minutes = 0.0
    @completed_since_last_tick = 0
    @arrivals_since_last_tick = 0
    @latencies_since_last_tick = []
    @current_time = 0.0

    build_control_loop

    max_time = @timing[:max_time]

    # Seed arrival events
    arrival = build_arrival_process
    arrival.seed_events(@queue)

    # Push initial autoscaler tick
    @queue.push(0.0, :autoscaler_tick, {})

    # Main event loop
    while (event = @queue.pop)
      time, type, payload = event
      break if time > max_time

      @current_time = time
      dispatch(time, type, payload)
    end

    @progress_reporter&.finish

    @trace.snapshots
  end

  private

  def build_control_loop
    # Capture in locals — Sensor.for uses define_method which changes self context
    pool = @pool
    ready_queue = @ready_queue
    completed_counter = -> { @completed_since_last_tick }
    clock = -> { @current_time }
    sensors = {
      active_workers: Skaler::Sensor.from { pool.worker_count },
      busy_threads: Skaler::Sensor.from { pool.busy_count },
      capacity: Skaler::Sensor.from { pool.capacity },
      ready_queue_depth: Skaler::Sensor.from { ready_queue.size },
      completed_since_last: Skaler::Sensor.from { completed_counter.call }
    }

    store = Skaler::MemoryMetricStore.new(clock: clock)

    pid = Skaler::PidController.new(
      kp: @pid_config[:kp],
      ki: @pid_config[:ki],
      kd: @pid_config[:kd],
      deadband: @pid_config[:deadband]
    )

    pg_pool_size = @constraints[:pg_pool_size]
    redis_pool_per_worker = @constraints[:redis_pool_per_worker]

    constraints = [
      Skaler::PooledResourceConstraint.new(cap: @constraints[:pg_max], pool_per_worker: pg_pool_size, name: :pg),
      Skaler::PooledResourceConstraint.new(cap: @constraints[:redis_max], pool_per_worker: redis_pool_per_worker, name: :redis),
      Skaler::MaxInstancesConstraint.new(max: @pool_config[:max_workers])
    ]

    controller = Skaler::Controller.new(
      pid: pid,
      constraints: constraints,
      setpoint: @pid_config[:setpoint],
      smoothing_alpha: @smoothing_alpha,
      metric_mode: @metric_mode,
      warm_up_duration: 0.0
    )

    @actuator = Skaler::SimulatedActuator.new(
      pool: @pool,
      clock: -> { @current_time },
      boot_lag: @timing[:boot_lag_seconds],
      cooldown: @timing[:cooldown_seconds],
      min_workers: @pool_config[:min_workers],
      max_workers: @pool_config[:max_workers]
    )

    @controller = controller

    @loop = Skaler::Loop.new(
      sensors: sensors,
      store: store,
      controller: controller,
      actuator: @actuator,
      observer: @trace
    )
  end

  def build_arrival_process
    if @arrival_process_config.is_a?(Skaler::ArrivalProcess)
      @arrival_process_config
    else
      Skaler::ArrivalProcess.new(
        mode: @arrival_process_config[:mode],
        rate_per_minute: @arrival_process_config[:rate_per_minute],
        default_type: @arrival_process_config[:default_type],
        max_time: @timing[:max_time],
        rng: @rng,
        schedule: @arrival_process_config[:schedule],
        batch_size: @arrival_process_config.fetch(:batch_size, 1),
        type_weights: @arrival_process_config[:type_weights],
        burst_ratio: @arrival_process_config.fetch(:burst_ratio, 0.7)
      )
    end
  end

  def dispatch(time, type, payload)
    case type
    when :job_arrived
      handle_job_arrived(time, payload)
    when :job_completed
      handle_job_completed(time, payload)
    when :autoscaler_tick
      handle_autoscaler_tick(time)
    when :workers_booted
      handle_workers_booted(time, payload)
    when :bulk_arrival
      handle_bulk_arrival(time, payload)
    end
  end

  # --- Event handlers ---

  def handle_job_arrived(time, payload)
    @arrivals_since_last_tick += 1
    try_start_job(time, payload[:job_type])
  end

  def handle_bulk_arrival(time, payload)
    count = payload[:count]
    count.times do
      @arrivals_since_last_tick += 1
      try_start_job(time, payload[:job_type])
    end
  end

  def try_start_job(time, job_type_name)
    if @pool.acquire
      job_type = @job_types.fetch(job_type_name)
      duration = job_type.sample_duration(@rng)
      @queue.push(time + duration, :job_completed, {job_type: job_type_name})
    else
      @ready_queue << [job_type_name, time]
    end
  end

  def handle_job_completed(time, payload)
    @pool.release
    @completed_since_last_tick += 1

    # Roll cascade dice
    job_type = @job_types.fetch(payload[:job_type])
    cascades = job_type.roll_cascades(@rng)
    cascades.each do |cascade|
      cascade[:count].times do
        @arrivals_since_last_tick += 1
        try_start_job(time, cascade[:child_type])
      end
    end

    # Drain ready queue into freed slot
    drain_ready_queue(time)
  end

  def drain_ready_queue(time)
    while @pool.free_count > 0 && !@ready_queue.empty?
      job_type_name, arrived_at = @ready_queue.shift
      if @pool.acquire
        @latencies_since_last_tick << (time - arrived_at)
        job_type = @job_types.fetch(job_type_name)
        duration = job_type.sample_duration(@rng)
        @queue.push(time + duration, :job_completed, {job_type: job_type_name})
      end
    end
  end

  def handle_workers_booted(_time, payload)
    count = payload[:count]
    @pool.add_workers(count)
  end

  def percentile(sorted, pct)
    return 0 if sorted.empty?
    k = (pct / 100.0 * (sorted.size - 1))
    f = k.floor
    c = k.ceil
    return sorted[f] if f == c
    sorted[f] + (k - f) * (sorted[c] - sorted[f])
  end

  def handle_autoscaler_tick(time)
    # Process pending boot completions (actuator manages these)
    @actuator.process_boots(time)

    # Drain ready queue with any newly available slots
    drain_ready_queue(time)

    # Run the control loop: sensors → store → controller → actuator
    @loop.step

    # Append simulator-specific fields to the snapshot recorded by Trace#on_step
    snapshot = @trace.snapshots.last
    if snapshot
      interval_minutes = @timing[:autoscaler_interval] / 60.0
      instance_minutes = @pool.worker_count * interval_minutes
      @cumulative_instance_minutes += instance_minutes

      snapshot[:completed_since_last] = @completed_since_last_tick
      snapshot[:arrivals_since_last] = @arrivals_since_last_tick
      snapshot[:instance_minutes] = instance_minutes
      snapshot[:cumulative_instance_minutes] = @cumulative_instance_minutes
      snapshot[:pending_boots] = @actuator.pending_count

      sorted_latencies = @latencies_since_last_tick.sort
      snapshot[:latency_p50] = percentile(sorted_latencies, 50)
      snapshot[:latency_p95] = percentile(sorted_latencies, 95)
      snapshot[:latency_max] = sorted_latencies.last || 0
    end

    # Reset per-tick counters
    @completed_since_last_tick = 0
    @arrivals_since_last_tick = 0
    @latencies_since_last_tick = []

    # Report progress
    @progress_reporter&.tick(time)

    # Schedule next tick
    next_tick_time = time + @timing[:autoscaler_interval]
    if next_tick_time <= @timing[:max_time]
      @queue.push(next_tick_time, :autoscaler_tick, {})
    end
  end
end
