require "solid_queue_test_helper"

class Skaler::ClaimedJobsSensorTest < Skaler::SolidQueueTestCase
  test "take_measurement returns claimed execution count" do
    SolidQueue::ClaimedExecution.stub(:count, 42) do
      assert_equal 42, Skaler::ClaimedJobsSensor.new.take_measurement
    end
  end
end
