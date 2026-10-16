# Detects thread pool size from the most recently heartbeating worker's metadata.
#
# Falls back to 5 if metadata is unavailable.
#
# @example
#   sensor = Skaler::ThreadsPerWorkerSensor.new
#   sensor.take_measurement # => 5
class Skaler::ThreadsPerWorkerSensor < Skaler::Sensor
  DEFAULT_THREADS = 5

  def take_measurement
    worker = Skaler::ActiveWorkersSensor.live_workers
      .order(last_heartbeat_at: :desc)
      .first

    metadata = worker&.metadata
    return DEFAULT_THREADS unless metadata.is_a?(Hash)

    threads = metadata["thread_pool_size"] || metadata["threads"]
    (threads.is_a?(Integer) && threads > 0) ? threads : DEFAULT_THREADS
  end
end
