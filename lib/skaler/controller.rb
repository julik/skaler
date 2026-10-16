# Control-loop controller that computes a scaling delta from metric store state.
#
# Wraps the proven `Skaler::PidController` math and pluggable `Skaler::Constraint`
# objects. Owns EMA smoothing, warm-up gating, signal history, and deadband.
# Does NOT own cooldown, min/max bounds, or execution — those are Actuator concerns.
#
# Constraints are self-contained objects that own their configuration (caps,
# pool sizes, etc.) and receive only `active_workers:` — they are not coupled
# to sensor names or the measurements hash.
#
# Stateless — all mutable state (signal history, EMA) is loaded from and saved
# to the MetricStore at each step. This allows the controller to be
# re-instantiated each tick (as in production job scheduling) without losing
# PID integral/derivative continuity.
#
# @example
#   controller = Skaler::Controller.new(
#     pid: Skaler::PidController.new(kp: 0.8, ki: 0.1, kd: 0.35, deadband: 0.1),
#     constraints: [
#       Skaler::PooledResourceConstraint.new(cap: 2000, pool_per_worker: 7, name: :pg),
#       Skaler::MaxInstancesConstraint.new(max: 60)
#     ],
#     setpoint: 0.7,
#     smoothing_alpha: 0.15,
#     metric_mode: "utilization",
#     warm_up_duration: 120
#   )
#   delta = controller.step(store)  # => +3, -1, or 0
#   controller.last_state           # => { smoothed_utilization: 0.72, ... }
class Skaler::Controller
  attr_reader :last_state

  # Rolling window for the integral term. At 60s intervals this is ~10 minutes —
  # long enough to correct steady-state error, short enough to avoid windup.
  SIGNAL_HISTORY_WINDOW = 10

  # Safety clamps — applied after PID math to prevent derivative spikes
  # and runaway scaling from rapid ticks or sudden utilization jumps.
  MAX_D_TERM = 10.0        # Max absolute D contribution
  MAX_PID_OUTPUT = 15.0    # Max absolute PID output
  MIN_TICK_INTERVAL = 2.0  # Minimum seconds between ticks (safety net for sub-second double-fires)

  # @param pid [Skaler::PidController] PID math engine
  # @param constraints [Array<Skaler::Constraint>] pluggable resource constraints
  # @param setpoint [Float] target utilization
  # @param smoothing_alpha [Float] EMA smoothing factor
  # @param metric_mode [String] "utilization" or "pressure"
  # @param warm_up_duration [Numeric] seconds of data required before acting (0 to disable)
  # @param min_action_interval [Numeric] minimum seconds between non-zero deltas (0 to disable).
  #   Shorthand that sets both up and down intervals to the same value.
  # @param min_action_interval_up [Numeric] minimum seconds between scale-up actions (0 to disable).
  #   The controller still computes PID on every tick (keeping EMA, integral, and derivative
  #   current), but suppresses actuation until the interval elapses. This decouples the
  #   observation rate from the actuation rate — sample fast for signal quality, act slow
  #   enough that booted instances have time to be useful.
  # @param min_action_interval_down [Numeric] minimum seconds between scale-down actions (0 to disable).
  #   Typically shorter than the up interval (or zero) to allow prompt scale-down and
  #   prevent upward ratcheting when load spikes are frequent.
  def initialize(
    pid:,
    constraints:,
    setpoint:,
    smoothing_alpha: 0.15,
    metric_mode: "utilization",
    warm_up_duration: 0.0,
    min_action_interval: 0.0,
    min_action_interval_up: nil,
    min_action_interval_down: nil
  )
    @pid = pid
    @constraints = constraints
    @setpoint = setpoint
    @smoothing_alpha = smoothing_alpha
    @metric_mode = metric_mode
    @warm_up_duration = warm_up_duration
    @min_action_interval_up = min_action_interval_up || min_action_interval
    @min_action_interval_down = min_action_interval_down || min_action_interval
    @last_state = {}
  end

  # Compute a scaling delta from the current metric store state.
  #
  # @param store [Skaler::MetricStore] the metric store to read from
  # @return [Integer] signed delta (positive = scale up, negative = scale down, 0 = no action)
  def step(store)
    unless store.ready?(min_duration: @warm_up_duration)
      @last_state = {warm_up: true, delta: 0}
      return 0
    end

    latest = store.latest
    unless latest
      @last_state = {no_data: true, delta: 0}
      return 0
    end

    # Evaluate constraints eagerly — headroom is useful for observability
    # even on skipped ticks. Constraints only need active_workers.
    active_workers = latest.fetch(:active_workers, 0)
    constraint_results = @constraints.map { |c| c.evaluate(active_workers: active_workers) }
    max_additional = constraint_results.map { |r| r[:max_additional] }.min || Float::INFINITY
    # Merge only the detail keys (headroom_pg, headroom_redis, ...): every result
    # also carries :max_additional, and letting the last constraint's value shadow
    # the min above would misreport the binding ceiling in last_state.
    constraint_details = constraint_results.reduce({}) { |merged, r| merged.merge(r.except(:max_additional)) }

    # Skip ticks where capacity is zero (worker restart / deployment gaps).
    # Do NOT update any PID state — the next valid tick resumes as if the
    # gap never happened. This prevents 0.0 from poisoning the EMA.
    capacity = latest.fetch(:capacity, 0)
    busy = latest.fetch(:busy_threads, latest.fetch(:claimed_jobs, 0))
    if capacity <= 0 && busy <= 0
      logger.info "[Skaler::Controller] Skipping tick: zero capacity and zero busy threads"
      @last_state = {zero_capacity: true, delta: 0, max_additional: max_additional}.merge(constraint_details)
      return 0
    end

    # Load persisted state (signal history, EMA, last action time) from the store
    saved = store.load_controller_state
    smoothed_utilization = saved ? (saved[:smoothed_utilization] || 0.0) : 0.0
    signal_history = saved ? (saved[:signal_history] || []) : []
    last_action_at = saved ? saved[:last_action_at] : nil

    raw_utilization = compute_raw_utilization(latest)
    smoothed_utilization = @smoothing_alpha * raw_utilization + (1 - @smoothing_alpha) * smoothed_utilization
    error = smoothed_utilization - @setpoint

    # PID computation using a rolling window of signal history.
    # Only the most recent entries feed the integral — older errors age out
    # so the I term stabilizes instead of drifting monotonically.
    # Trim to window size to bound memory growth across ticks.
    signal_history = signal_history.last(SIGNAL_HISTORY_WINDOW)
    now = store.now

    # Guard against rapid or non-monotonic ticks. Negative dt means clock
    # went backwards (e.g. NTP adjustment); sub-threshold dt means ticks
    # arrived too fast. Either way, skip — no PID output is safe here.
    if signal_history.any?
      last_ts = signal_history.last[1]
      dt = now - last_ts
      if dt <= 0
        logger.warn "[Skaler::Controller] Skipping tick: non-monotonic dt=#{dt.round(1)}s"
        @last_state = {skipped_tick: true, dt: dt, delta: 0, max_additional: max_additional}.merge(constraint_details)
        return 0
      elsif dt < MIN_TICK_INTERVAL
        logger.info "[Skaler::Controller] Skipping tick: dt=#{dt.round(1)}s < MIN_TICK_INTERVAL=#{MIN_TICK_INTERVAL}s"
        @last_state = {skipped_tick: true, dt: dt, delta: 0, max_additional: max_additional}.merge(constraint_details)
        store.save_controller_state(
          smoothed_utilization: smoothed_utilization,
          signal_history: signal_history
        )
        return 0
      end
    end

    observed_dt = median_dt(signal_history, now)
    pid_result = @pid.compute(error: error, signal_history: signal_history, now: now, nominal_dt: observed_dt)

    # Clamp D term to prevent derivative spikes from amplifying scaling.
    # Adjust output by the excess rather than recomputing from p+i+d,
    # so we preserve any additional logic PidController applies to output.
    raw_d = pid_result[:d]
    if raw_d.abs > MAX_D_TERM
      clamped_d = raw_d.clamp(-MAX_D_TERM, MAX_D_TERM)
      logger.info "[Skaler::Controller] Clamping D term: #{raw_d.round(2)} -> #{clamped_d.round(2)}"
      pid_result = pid_result.merge(d: clamped_d, output: pid_result[:output] - (raw_d - clamped_d))
    end

    # Clamp total PID output to bound scaling magnitude
    raw_output = pid_result[:output]
    if raw_output.abs > MAX_PID_OUTPUT
      clamped_output = raw_output.clamp(-MAX_PID_OUTPUT, MAX_PID_OUTPUT)
      logger.info "[Skaler::Controller] Clamping PID output: #{raw_output.round(2)} -> #{clamped_output.round(2)}"
      pid_result = pid_result.merge(output: clamped_output)
    end

    signal_history << [error, now]

    delta = if pid_result[:deadband]
      0
    elsif pid_result[:output] > 0
      desired = pid_result[:output].ceil
      [desired, max_additional].min
    elsif pid_result[:output] < 0
      -pid_result[:output].abs.ceil
    else
      0
    end

    # Action interval hold: suppress non-zero deltas if we acted too recently.
    # Uses asymmetric intervals — scale-up can be held longer than scale-down
    # to prevent upward ratcheting when load spikes are frequent.
    # The PID state (EMA, integral, derivative) is already updated above, so
    # the next tick that does act will reflect the accumulated error.
    held = false
    if delta != 0 && last_action_at
      interval = (delta > 0) ? @min_action_interval_up : @min_action_interval_down
      if interval > 0
        elapsed = now - last_action_at
        if elapsed < interval
          logger.info "[Skaler::Controller] Holding action: #{elapsed.round(1)}s since last action < min_action_interval_#{(delta > 0) ? "up" : "down"}=#{interval}s (would-be delta=#{delta})"
          held = true
          delta = 0
        end
      end
    end

    # Update last_action_at when we actually act
    last_action_at = now if delta != 0

    # Persist state — includes last_action_at so the hold survives across
    # controller re-instantiations (stateless design).
    store.save_controller_state(
      smoothed_utilization: smoothed_utilization,
      signal_history: signal_history,
      last_action_at: last_action_at
    )

    @last_state = {
      raw_utilization: raw_utilization,
      smoothed_utilization: smoothed_utilization,
      error: error,
      p: pid_result[:p],
      i: pid_result[:i],
      d: pid_result[:d],
      output: pid_result[:output],
      deadband: pid_result[:deadband],
      delta: delta,
      max_additional: max_additional,
      nominal_dt: observed_dt,
      held: held
    }.merge(constraint_details)

    delta
  end

  private

  def logger
    Skaler.logger
  end

  # Compute the median dt (seconds) from signal history timestamps.
  # Falls back to DEFAULT_NOMINAL_DT when there aren't enough samples.
  #
  # @param signal_history [Array<Array(Float, Numeric)>] [error, timestamp] pairs
  # @param now [Numeric] current timestamp
  # @return [Float] median dt in seconds
  def median_dt(signal_history, now)
    # Need at least one prior sample to compute any dt
    return Skaler::PidController::DEFAULT_NOMINAL_DT if signal_history.empty?

    # Collect dt values: between consecutive history entries + from last entry to now
    dts = []
    signal_history.each_cons(2) { |(_, t1), (_, t2)| dts << (t2 - t1) }
    dts << (now - signal_history.last[1])

    # Median of the collected intervals
    sorted = dts.sort
    mid = sorted.size / 2
    sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
  end

  # Compute raw utilization from latest measurements.
  #
  # @param latest [Hash] most recent measurements
  # @return [Float] raw utilization value
  def compute_raw_utilization(latest)
    reported_capacity = latest.fetch(:capacity, 0)
    busy = latest.fetch(:busy_threads, latest.fetch(:claimed_jobs, 0))

    # Use claimed jobs as a capacity floor: if there are N claimed executions,
    # there must be at least N threads alive to claim them. This eliminates
    # denominator-driven spikes when the sensor catches workers mid-boot/shutdown.
    capacity = [reported_capacity, busy].max
    return 0.0 if capacity <= 0

    case @metric_mode
    when "pressure"
      util = busy.to_f / capacity
      completed = [latest.fetch(:completed_jobs, latest.fetch(:completed_since_last, 1)), 1].max
      ready = latest.fetch(:ready_jobs, latest.fetch(:ready_queue_depth, 0))
      queue_factor = [ready.to_f / completed, 3.0].min
      [util + queue_factor, 4.0].min
    else # "utilization"
      busy.to_f / capacity
    end
  end
end
