require "test_helper"

class Skaler::MaxInstancesConstraintTest < Skaler::TestCase
  test "allows scaling up to max" do
    constraint = Skaler::MaxInstancesConstraint.new(max: 60)

    result = constraint.evaluate(active_workers: 10)
    assert_equal 50, result[:max_additional]
  end

  test "returns zero when already at max" do
    constraint = Skaler::MaxInstancesConstraint.new(max: 60)

    result = constraint.evaluate(active_workers: 60)
    assert_equal 0, result[:max_additional]
  end

  test "clamps negative to zero when over max" do
    constraint = Skaler::MaxInstancesConstraint.new(max: 60)

    result = constraint.evaluate(active_workers: 65)
    assert_equal 0, result[:max_additional]
  end

  test "works with zero workers" do
    constraint = Skaler::MaxInstancesConstraint.new(max: 10)

    result = constraint.evaluate(active_workers: 0)
    assert_equal 10, result[:max_additional]
  end
end
