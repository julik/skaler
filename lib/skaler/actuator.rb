# Abstract base class for control-loop actuators.
#
# An actuator receives a signed delta from the controller and executes the
# scaling action. It owns cooldown enforcement, boot-lag tracking, and
# min/max instance bounds.
#
# @example
#   actuator = Skaler::SimulatedActuator.new(pool: pool, clock: -> { time })
#   result = actuator.scale(3)   # => :scaled_up
#   result = actuator.scale(-1)  # => :scaled_down
#   result = actuator.scale(0)   # => :noop
class Skaler::Actuator
  # Execute a scaling action.
  #
  # @param delta [Integer] signed number of instances to add (positive) or remove (negative)
  # @return [Symbol] one of :scaled_up, :scaled_down, :noop, :cooldown
  def scale(delta)
    raise NotImplementedError
  end
end
