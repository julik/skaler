require "solid_queue_test_helper"

class Skaler::ActiveWorkersSensorTest < Skaler::SolidQueueTestCase
  test "take_measurement is zero with no SolidQueue processes" do
    assert_equal 0, Skaler::ActiveWorkersSensor.new.take_measurement
  end

  test "take_measurement counts workers with recent heartbeats" do
    add_worker(heartbeat_age: 5)
    add_worker(heartbeat_age: 60)
    add_worker(heartbeat_age: 600) # stale, presumed dead
    SolidQueue::Process.create!(kind: "Dispatcher", last_heartbeat_at: Time.now, metadata: {})

    assert_equal 2, Skaler::ActiveWorkersSensor.new.take_measurement
  end
end
