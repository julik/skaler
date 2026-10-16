# Hard ceiling constraint on total instance count.
#
# Prevents scaling beyond a configured maximum regardless of other resource availability.
#
# @example
#   Skaler::MaxInstancesConstraint.new(max: 60)
class Skaler::MaxInstancesConstraint < Skaler::Constraint
  # @param max [Integer] absolute maximum number of workers
  def initialize(max:)
    @max = max
  end

  # @param active_workers [Integer] current number of active workers
  # @return [Hash] { max_additional: Integer }
  def evaluate(active_workers:)
    {max_additional: [@max - active_workers, 0].max}
  end
end
