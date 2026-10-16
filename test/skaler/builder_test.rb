require "test_helper"

class Skaler::BuilderTest < Skaler::TestCase
  test ".simulation returns a Loop and Simulated actuator" do
    pool = Skaler::WorkerPool.new(worker_count: 2, threads_per_worker: 5)
    time = 0.0
    clock = -> { time }

    sensors = {
      active_workers: Skaler::Sensor.from { pool.worker_count },
      busy_threads: Skaler::Sensor.from { pool.busy_count },
      capacity: Skaler::Sensor.from { pool.capacity },
      ready_queue_depth: Skaler::Sensor.from { 0 },
      completed_since_last: Skaler::Sensor.from { 5 }
    }

    trace = Skaler::Trace.new

    loop_instance, actuator = Skaler::Builder.simulation(
      sensors: sensors,
      pool: pool,
      pid_config: {kp: 0.8, ki: 0.1, kd: 0.35, deadband: 0.1, setpoint: 0.7},
      pool_config: {min_workers: 2, max_workers: 60},
      constraints_config: {pg_pool_size: 7, redis_pool_per_worker: 10, pg_max: 2000, redis_max: 5000},
      timing: {boot_lag_seconds: 60, cooldown_seconds: 15},
      smoothing_alpha: 0.15,
      metric_mode: "utilization",
      clock: clock,
      trace: trace
    )

    assert_instance_of Skaler::Loop, loop_instance
    assert_instance_of Skaler::SimulatedActuator, actuator
  end

  test ".simulation produces valid trace on step" do
    pool = Skaler::WorkerPool.new(worker_count: 2, threads_per_worker: 5)
    time = 0.0
    clock = -> { time }

    sensors = {
      active_workers: Skaler::Sensor.from { pool.worker_count },
      busy_threads: Skaler::Sensor.from { pool.busy_count },
      capacity: Skaler::Sensor.from { pool.capacity },
      ready_queue_depth: Skaler::Sensor.from { 0 },
      completed_since_last: Skaler::Sensor.from { 5 }
    }

    trace = Skaler::Trace.new

    loop_instance, _actuator = Skaler::Builder.simulation(
      sensors: sensors,
      pool: pool,
      pid_config: {kp: 0.8, ki: 0.1, kd: 0.35, deadband: 0.1, setpoint: 0.7},
      pool_config: {min_workers: 2, max_workers: 60},
      constraints_config: {pg_pool_size: 7, redis_pool_per_worker: 10, pg_max: 2000, redis_max: 5000},
      timing: {boot_lag_seconds: 60, cooldown_seconds: 15},
      smoothing_alpha: 0.15,
      metric_mode: "utilization",
      clock: clock,
      trace: trace
    )

    loop_instance.step
    assert_equal 1, trace.size

    snapshot = trace.snapshots.first
    assert snapshot.key?(:t)
    assert snapshot.key?(:utilization)
    assert snapshot.key?(:instances)
    assert snapshot.key?(:pg_headroom)
    assert snapshot.key?(:redis_headroom)
  end
end
