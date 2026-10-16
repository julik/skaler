require "test_helper"

class Skaler::LoopTest < Skaler::TestCase
  setup do
    @time = 0.0
    @pool = Skaler::WorkerPool.new(worker_count: 5, threads_per_worker: 5)

    pool = @pool
    clock = -> { @time }

    @sensors = {
      active_workers: Skaler::Sensor.from { pool.worker_count },
      busy_threads: Skaler::Sensor.from { pool.busy_count },
      capacity: Skaler::Sensor.from { pool.capacity },
      ready_queue_depth: Skaler::Sensor.from { 0 },
      completed_since_last: Skaler::Sensor.from { 10 }
    }

    @store = Skaler::MemoryMetricStore.new(clock: clock)

    pid = Skaler::PidController.new(kp: 0.8, ki: 0.1, kd: 0.35, deadband: 0.1)
    constraints = [
      Skaler::PooledResourceConstraint.new(cap: 2000, pool_per_worker: 7, name: :pg),
      Skaler::PooledResourceConstraint.new(cap: 5000, pool_per_worker: 10, name: :redis),
      Skaler::MaxInstancesConstraint.new(max: 60)
    ]
    @controller = Skaler::Controller.new(
      pid: pid,
      constraints: constraints,
      setpoint: 0.7,
      smoothing_alpha: 0.5
    )

    @actuator = Skaler::SimulatedActuator.new(
      pool: @pool,
      clock: clock,
      boot_lag: 60,
      cooldown: 10,
      min_workers: 2,
      max_workers: 60
    )

    @observer_calls = []
    observer_calls = @observer_calls
    @observer = Object.new
    @observer.define_singleton_method(:on_step) do |**kwargs|
      observer_calls << kwargs
    end

    @loop = Skaler::Loop.new(
      sensors: @sensors,
      store: @store,
      controller: @controller,
      actuator: @actuator,
      observer: @observer
    )
  end

  test "step reads sensors, stores, and returns result" do
    result = @loop.step
    assert_includes [:noop, :scaled_up, :scaled_down, :cooldown], result

    # Store should have one entry
    entries = @store.recall(over_last: 100)
    assert_equal 1, entries.size
    assert_equal 5, entries.first[:active_workers]
    assert_equal 25, entries.first[:capacity]
  end

  test "observer receives on_step callback after step" do
    @loop.step
    assert_equal 1, @observer_calls.size

    call = @observer_calls.first
    assert_equal 0.0, call[:time]
    assert call[:measurements].is_a?(Hash)
    assert call[:controller_state].is_a?(Hash)
    assert call.key?(:delta)
    assert call.key?(:result)
  end

  test "works without observer" do
    loop_obj = Skaler::Loop.new(
      sensors: @sensors,
      store: @store,
      controller: @controller,
      actuator: @actuator
    )
    result = loop_obj.step
    assert_includes [:noop, :scaled_up, :scaled_down, :cooldown], result
  end

  test "multiple steps accumulate measurements" do
    @loop.step
    @time = 60.0
    @loop.step
    @time = 120.0
    @loop.step

    entries = @store.recall(over_last: 300)
    assert_equal 3, entries.size
  end

  test "high utilization triggers scale up" do
    # Acquire most slots to create high utilization
    20.times { @pool.acquire }

    5.times do |i|
      @time = i * 60.0
      @loop.step
    end

    # At some point the actuator should have received a scale-up
    assert @actuator.pending_count > 0 || @pool.worker_count > 5,
      "Expected scaling activity with high utilization"
  end
end
