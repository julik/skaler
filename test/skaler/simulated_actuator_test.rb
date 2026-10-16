require "test_helper"

class Skaler::SimulatedActuatorTest < Skaler::TestCase
  setup do
    @time = 0.0
    @pool = Skaler::WorkerPool.new(worker_count: 5, threads_per_worker: 5)
    @actuator = Skaler::SimulatedActuator.new(
      pool: @pool,
      clock: -> { @time },
      boot_lag: 120,
      cooldown: 15,
      min_workers: 2,
      max_workers: 20
    )
  end

  test "scale up creates pending boots" do
    result = @actuator.scale(3)
    assert_equal :scaled_up, result
    assert_equal 1, @actuator.pending_boots.size
    assert_equal 3, @actuator.pending_count
    # Workers not yet added
    assert_equal 5, @pool.worker_count
  end

  test "process_boots materializes workers after boot lag" do
    @actuator.scale(3)
    @time = 119.0
    @actuator.process_boots(@time)
    assert_equal 5, @pool.worker_count # not ready yet

    @time = 120.0
    @actuator.process_boots(@time)
    assert_equal 8, @pool.worker_count # now booted
    assert_equal 0, @actuator.pending_count
  end

  test "cooldown prevents rapid scaling" do
    @actuator.scale(2)
    @time = 10.0 # within cooldown
    result = @actuator.scale(1)
    assert_equal :cooldown, result
  end

  test "cooldown expires and allows scaling" do
    @actuator.scale(2)
    # Process boots so pending is clear
    @time = 120.0
    @actuator.process_boots(@time)

    @time = 135.0 # cooldown of 15s elapsed from t=0
    result = @actuator.scale(1)
    assert_equal :scaled_up, result
  end

  test "cannot scale up while boots are pending" do
    @actuator.scale(2)
    @time = 20.0 # cooldown elapsed but boots still pending
    result = @actuator.scale(1)
    assert_equal :cooldown, result
  end

  test "scale down removes workers immediately" do
    result = @actuator.scale(-2)
    assert_equal :scaled_down, result
    assert_equal 3, @pool.worker_count
  end

  test "scale down respects min_workers" do
    @actuator.scale(-10)
    assert_equal 2, @pool.worker_count # min_workers
  end

  test "scale up respects max_workers" do
    @actuator.scale(20)
    assert_equal 15, @actuator.pending_count # max 20 - current 5
  end

  test "scale zero returns noop" do
    assert_equal :noop, @actuator.scale(0)
  end

  test "scale down to exactly min_workers returns noop for further scale-down" do
    @actuator.scale(-3) # 5 -> 2
    assert_equal 2, @pool.worker_count

    @time = 20.0
    result = @actuator.scale(-1)
    assert_equal :noop, result
  end
end
