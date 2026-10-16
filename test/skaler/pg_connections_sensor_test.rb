require "solid_queue_test_helper"

class Skaler::PgConnectionsSensorTest < Skaler::SolidQueueTestCase
  test "estimates connections as active workers times pool size" do
    3.times { add_worker }
    assert_equal 21, Skaler::PgConnectionsSensor.new.take_measurement
  end
end
