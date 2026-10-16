# Caps how many instances may be added in a single scaling action.
#
# Resource constraints are evaluated against a snapshot taken at the start of a
# tick, so one large jump can push usage past the budget before the next tick
# can observe it. Bounding the step keeps the loop's own overshoot inside what
# the next measurement can correct.
#
# @example At most 4 instances per action
#   Skaler::SlewRateConstraint.new(max_step: 4)
class Skaler::SlewRateConstraint < Skaler::Constraint
  # @param max_step [Integer] most instances addable in one action
  def initialize(max_step:)
    @max_step = max_step
  end

  # @param active_workers [Integer] ignored — the cap is per action, not a ceiling
  # @return [Hash] { max_additional: Integer }
  def evaluate(active_workers:)
    {max_additional: [@max_step.to_i, 0].max}
  end
end
