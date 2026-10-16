# Counts active SolidQueue worker processes with recent heartbeats.
#
# @example
#   sensor = Skaler::ActiveWorkersSensor.new
#   sensor.take_measurement # => 8
class Skaler::ActiveWorkersSensor < Skaler::Sensor
  HEARTBEAT_WINDOW = 300 # seconds

  # Workers whose heartbeat is recent enough to count as alive. Shared by the
  # SolidQueue sensors so they agree on what "active" means.
  #
  # @return [ActiveRecord::Relation]
  def self.live_workers
    SolidQueue::Process
      .where(kind: "Worker")
      .where("last_heartbeat_at > ?", Time.now - HEARTBEAT_WINDOW)
  end

  def take_measurement
    self.class.live_workers.count
  end
end
