# Abstract base class for scaling constraints.
#
# Each constraint computes a max-additional-instances limit independently.
# Constraints own their configuration (caps, pool sizes, etc.) and receive
# only the current worker count as input — they are not coupled to sensor
# names or the measurements hash.
#
# The controller evaluates all constraints and takes the minimum to clamp
# the PID output.
#
# @example Implementing a custom constraint
#   class Skaler::MyLimitConstraint < Skaler::Constraint
#     def evaluate(active_workers:)
#       headroom = compute_headroom(active_workers)
#       { max_additional: [headroom, 0].max }
#     end
#   end
class Skaler::Constraint
  # Evaluate this constraint given the current worker count.
  #
  # @param active_workers [Integer] current number of active workers
  # @return [Hash] must include :max_additional (Integer), may include extra detail keys
  def evaluate(active_workers:)
    raise NotImplementedError, "#{self.class}#evaluate must return a Hash with :max_additional"
  end
end
