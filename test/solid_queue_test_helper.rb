require "test_helper"
require_relative "support/fake_solid_queue"
require "skaler/solid_queue"

module Skaler
  class SolidQueueTestCase < TestCase
    setup do
      SolidQueue.reset_fakes!
    end

    def add_worker(heartbeat_age: 10, metadata: {})
      SolidQueue::Process.create!(kind: "Worker", last_heartbeat_at: Time.now - heartbeat_age, metadata: metadata)
    end
  end
end
