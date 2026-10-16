# Abstract base class for control-loop sensors.
#
# A sensor reads a single measurement from the system. Subclass and implement
# {#take_measurement}. The sensor does not know its own name — names are
# assigned externally when wiring the sensors hash into a {Skaler::Loop}.
#
# @example Named subclass
#   class Skaler::ClaimedJobsSensor < Skaler::Sensor
#     def take_measurement = SolidQueue::ClaimedExecution.count
#   end
#
# @example Lambda sensor via factory
#   sensor = Skaler::Sensor.from { pool.busy_count }
#   sensor.take_measurement # => 12
class Skaler::Sensor
  # @return [Numeric] current measurement value
  def take_measurement
    raise NotImplementedError, "#{self.class}#take_measurement must return a Numeric"
  end

  # Factory for creating simple lambda-backed sensors.
  #
  # @yield block that returns the measurement value
  # @return [Skaler::Sensor] a new sensor instance
  def self.from(&block)
    Class.new(self) {
      define_method(:take_measurement, &block)
    }.new
  end
end
