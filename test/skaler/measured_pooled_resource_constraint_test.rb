require "test_helper"

class Skaler::MeasuredPooledResourceConstraintTest < Skaler::TestCase
  def build(usage:, cap: 1000, pool_per_worker: 20, target_utilization: 0.75)
    Skaler::MeasuredPooledResourceConstraint.new(
      usage: usage,
      cap: cap,
      pool_per_worker: pool_per_worker,
      target_utilization: target_utilization,
      name: :redis
    )
  end

  test "hands out the slack under the target, not the whole cap" do
    result = build(usage: 300).evaluate(active_workers: 8)

    # budget = 750, slack = 450, 450 / 20 = 22
    assert_equal 22, result[:max_additional]
    assert_equal 22, result[:headroom_redis]
    assert_in_delta 0.3, result[:redis_utilization]
  end

  test "ignores the worker count so the model cannot drift from the measurement" do
    constraint = build(usage: 300)

    assert_equal constraint.evaluate(active_workers: 0), constraint.evaluate(active_workers: 40)
  end

  test "stops scaling once usage reaches the target" do
    result = build(usage: 750).evaluate(active_workers: 30)

    assert_equal 0, result[:max_additional]
  end

  test "reports negative headroom when already over budget" do
    result = build(usage: 883).evaluate(active_workers: 40)

    assert_equal 0, result[:max_additional]
    assert_operator result[:headroom_redis], :<, 0
    assert_in_delta 0.883, result[:redis_utilization]
  end

  # A worker-count budget can say there is room while Redis is already saturated.
  # Once measured usage is past the target, more workers must be refused however few there are
  test "refuses scale-up once measured usage passes the target, regardless of worker count" do
    {760 => 12, 880 => 40, 1000 => 41}.each do |connected, workers|
      result = build(usage: connected).evaluate(active_workers: workers)
      assert_equal 0, result[:max_additional],
        "allowed scale-up at #{connected}/1000 clients (#{workers} workers)"
    end
  end

  test "resolves callable usage and cap" do
    result = build(usage: -> { 300 }, cap: -> { 1000 }).evaluate(active_workers: 8)

    assert_equal 22, result[:max_additional]
  end

  test "fails closed when the measurement is unavailable" do
    [{usage: nil}, {cap: nil}, {cap: 0}, {pool_per_worker: 0}].each do |bad|
      result = build(usage: 300, **bad).evaluate(active_workers: 8)

      assert_equal 0, result[:max_additional], "expected zero headroom for #{bad.inspect}"
      assert_equal 0, result[:headroom_redis]
      assert_equal 0.0, result[:redis_utilization]
    end
  end
end
