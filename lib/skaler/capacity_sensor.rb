# Computes total worker capacity as active_workers * threads_per_worker.
#
# Reads both values from dedicated sensors to keep sensor responsibilities
# single-purpose. The Controller reads `:capacity` from the metric store
# to compute utilization.
#
# @example
#   sensor = Skaler::CapacitySensor.new
#   sensor.take_measurement # => 40  (8 workers * 5 threads)
class Skaler::CapacitySensor < Skaler::Sensor
  def initialize
    @workers_sensor = Skaler::ActiveWorkersSensor.new
    @threads_sensor = Skaler::ThreadsPerWorkerSensor.new
  end

  def take_measurement
    @workers_sensor.take_measurement * @threads_sensor.take_measurement
  end
end
