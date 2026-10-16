require "test_helper"

class Skaler::PooledResourceConstraintTest < Skaler::TestCase
  test "computes headroom from cap and pool size" do
    constraint = Skaler::PooledResourceConstraint.new(cap: 200, pool_per_worker: 7, name: :pg)

    result = constraint.evaluate(active_workers: 10)

    # max_workers = 200 / 7 = 28
    # headroom = 28 - 10 = 18
    assert_equal 18, result[:max_additional]
    assert_equal 18, result[:headroom_pg]
  end

  test "names the headroom key after the constraint" do
    constraint = Skaler::PooledResourceConstraint.new(cap: 500, pool_per_worker: 10, name: :redis)

    result = constraint.evaluate(active_workers: 5)

    # max_workers = 500 / 10 = 50, headroom = 45
    assert_equal 45, result[:max_additional]
    assert_equal 45, result[:headroom_redis]
  end

  test "returns zero when at capacity" do
    constraint = Skaler::PooledResourceConstraint.new(cap: 70, pool_per_worker: 7, name: :pg)

    # max_workers = 70 / 7 = 10
    result = constraint.evaluate(active_workers: 10)

    assert_equal 0, result[:max_additional]
    assert_equal 0, result[:headroom_pg]
  end

  test "clamps negative headroom to zero in max_additional" do
    constraint = Skaler::PooledResourceConstraint.new(cap: 70, pool_per_worker: 7, name: :pg)

    result = constraint.evaluate(active_workers: 15)

    # max_workers = 10, headroom = 10 - 15 = -5
    assert_equal 0, result[:max_additional]
    assert_equal(-5, result[:headroom_pg])
  end

  test "handles zero workers" do
    constraint = Skaler::PooledResourceConstraint.new(cap: 200, pool_per_worker: 7, name: :pg)

    result = constraint.evaluate(active_workers: 0)

    # max_workers = 28, headroom = 28
    assert_equal 28, result[:max_additional]
  end

  test "supports callable cap for dynamic resolution" do
    call_count = 0
    dynamic_cap = -> {
      call_count += 1
      500
    }

    constraint = Skaler::PooledResourceConstraint.new(cap: dynamic_cap, pool_per_worker: 10, name: :redis)

    result = constraint.evaluate(active_workers: 5)

    assert_equal 1, call_count
    # max_workers = 500 / 10 = 50, headroom = 45
    assert_equal 45, result[:max_additional]
  end
end
