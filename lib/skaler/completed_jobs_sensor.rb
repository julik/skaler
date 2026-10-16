# Counts jobs completed since a given point in time.
#
# Takes a `since` callable in constructor to keep `take_measurement` zero-arg.
#
# @example
#   sensor = Skaler::CompletedJobsSensor.new(since: -> { Time.now - 120 })
#   sensor.take_measurement # => 150
class Skaler::CompletedJobsSensor < Skaler::Sensor
  # @param since [#call] callable returning the Time cutoff for counting completions
  def initialize(since: -> { Time.now - 120 })
    @since = since
  end

  def take_measurement
    cutoff = @since.call
    SolidQueue::Job.where.not(finished_at: nil).where("finished_at > ?", cutoff).count
  end
end
