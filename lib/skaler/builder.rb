# Factory for assembling a Skaler control loop from configuration hashes.
#
# Eliminates hand-wiring of sensors, store, controller, and actuator.
# Currently provides a `.simulation` factory; production factories can be added later.
#
# Sensors measure the system state (worker counts, queue depth, etc.).
# Constraints are separate — they own their configuration (caps, pool sizes)
# and determine what the autoscaler is _allowed_ to do.
#
# @example Build a simulation loop
#   loop, actuator = Skaler::Builder.simulation(
#     sensors: [...],
#     pool: worker_pool,
#     pid_config: { kp: 0.8, ki: 0.1, kd: 0.35, deadband: 0.1, setpoint: 0.7 },
#     pool_config: { max_workers: 60 },
#     constraints_config: { pg_pool_size: 7, redis_pool_per_worker: 10, pg_max: 2000, redis_max: 5000 },
#     timing: { boot_lag_seconds: 120, cooldown_seconds: 15 },
#     smoothing_alpha: 0.15,
#     metric_mode: "utilization",
#     clock: -> { Time.now.to_f },
#     trace: Skaler::Trace.new
#   )
class Skaler::Builder
  # Build a simulation loop from config hashes.
  #
  # @param sensors [Array<Skaler::Sensor>] sensors to read each step
  # @param pool [Skaler::WorkerPool] simulated worker pool
  # @param pid_config [Hash] PID tuning: kp, ki, kd, deadband, setpoint
  # @param pool_config [Hash] min_workers, max_workers
  # @param constraints_config [Hash] pg_pool_size, redis_pool_per_worker, pg_max, redis_max
  # @param timing [Hash] boot_lag_seconds, cooldown_seconds
  # @param smoothing_alpha [Float] EMA factor
  # @param metric_mode [String] "utilization" or "pressure"
  # @param clock [Proc] returns current virtual time
  # @param trace [Skaler::Trace] observer for recording snapshots
  # @return [Array(Skaler::Loop, Skaler::SimulatedActuator)] the loop and actuator
  def self.simulation(sensors:, pool:, pid_config:, pool_config:, constraints_config:, timing:, smoothing_alpha:, metric_mode:, clock:, trace:)
    store = Skaler::MemoryMetricStore.new(clock: clock)

    pid = Skaler::PidController.new(
      kp: pid_config[:kp],
      ki: pid_config[:ki],
      kd: pid_config[:kd],
      deadband: pid_config[:deadband]
    )

    pg_pool_size = constraints_config[:pg_pool_size]
    redis_pool_per_worker = constraints_config[:redis_pool_per_worker]

    constraints = [
      Skaler::PooledResourceConstraint.new(cap: constraints_config[:pg_max], pool_per_worker: pg_pool_size, name: :pg),
      Skaler::PooledResourceConstraint.new(cap: constraints_config[:redis_max], pool_per_worker: redis_pool_per_worker, name: :redis),
      Skaler::MaxInstancesConstraint.new(max: pool_config[:max_workers])
    ]

    controller = Skaler::Controller.new(
      pid: pid,
      constraints: constraints,
      setpoint: pid_config[:setpoint],
      smoothing_alpha: smoothing_alpha,
      metric_mode: metric_mode,
      warm_up_duration: 0.0
    )

    actuator = Skaler::SimulatedActuator.new(
      pool: pool,
      clock: clock,
      boot_lag: timing[:boot_lag_seconds],
      cooldown: timing[:cooldown_seconds],
      min_workers: pool_config[:min_workers],
      max_workers: pool_config[:max_workers]
    )

    loop_instance = Skaler::Loop.new(
      sensors: sensors,
      store: store,
      controller: controller,
      actuator: actuator,
      observer: trace
    )

    [loop_instance, actuator]
  end
end
