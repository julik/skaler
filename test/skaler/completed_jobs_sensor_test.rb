require "solid_queue_test_helper"

class Skaler::CompletedJobsSensorTest < Skaler::SolidQueueTestCase
  test "accepts since callable in constructor" do
    sensor = Skaler::CompletedJobsSensor.new(since: -> { Time.now - 600 })
    assert_equal 0, sensor.take_measurement
  end

  test "counts only jobs finished after the cutoff" do
    SolidQueue::Job.create!(finished_at: Time.now - 30)
    SolidQueue::Job.create!(finished_at: Time.now - 90)
    SolidQueue::Job.create!(finished_at: Time.now - 3600)
    SolidQueue::Job.create!(finished_at: nil) # still running

    sensor = Skaler::CompletedJobsSensor.new(since: -> { Time.now - 120 })
    assert_equal 2, sensor.take_measurement
  end
end
