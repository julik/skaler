# Counts currently claimed (in-flight) job executions.
#
# @example
#   sensor = Skaler::ClaimedJobsSensor.new
#   sensor.take_measurement # => 42
class Skaler::ClaimedJobsSensor < Skaler::Sensor
  def take_measurement
    SolidQueue::ClaimedExecution.count
  end
end
