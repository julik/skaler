require "test_helper"

class Skaler::SlewRateConstraintTest < Skaler::TestCase
  test "caps additions at the configured step" do
    assert_equal 4, Skaler::SlewRateConstraint.new(max_step: 4).evaluate(active_workers: 10)[:max_additional]
  end

  test "is independent of the current worker count" do
    constraint = Skaler::SlewRateConstraint.new(max_step: 4)

    assert_equal constraint.evaluate(active_workers: 0), constraint.evaluate(active_workers: 59)
  end

  test "never returns a negative step" do
    assert_equal 0, Skaler::SlewRateConstraint.new(max_step: -1).evaluate(active_workers: 10)[:max_additional]
  end
end
