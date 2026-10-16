require "solid_queue_test_helper"

class Skaler::ThreadsPerWorkerSensorTest < Skaler::SolidQueueTestCase
  test "returns default when no workers present" do
    assert_equal 5, Skaler::ThreadsPerWorkerSensor.new.take_measurement
  end

  test "reads thread_pool_size from the most recently heartbeating worker" do
    add_worker(heartbeat_age: 60, metadata: {"thread_pool_size" => 3})
    add_worker(heartbeat_age: 5, metadata: {"thread_pool_size" => 12})
    assert_equal 12, Skaler::ThreadsPerWorkerSensor.new.take_measurement
  end

  test "falls back to default when metadata has no usable thread count" do
    add_worker(metadata: {"thread_pool_size" => "lots"})
    assert_equal 5, Skaler::ThreadsPerWorkerSensor.new.take_measurement
  end
end
