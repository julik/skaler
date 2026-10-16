require "solid_queue_test_helper"

class Skaler::ReadyJobsSensorTest < Skaler::SolidQueueTestCase
  test "counts all ready executions when workers do not report queues" do
    add_worker
    3.times { SolidQueue::ReadyExecution.create!(queue_name: "default") }
    assert_equal 3, Skaler::ReadyJobsSensor.new.take_measurement
  end

  test "only counts queues the live workers serve" do
    add_worker(metadata: {"queues" => "default,high"})
    SolidQueue::ReadyExecution.create!(queue_name: "default")
    SolidQueue::ReadyExecution.create!(queue_name: "high")
    SolidQueue::ReadyExecution.create!(queue_name: "web_only") # nobody autoscaled picks this up
    assert_equal 2, Skaler::ReadyJobsSensor.new.take_measurement
  end

  test "excludes paused queues" do
    add_worker
    SolidQueue::ReadyExecution.create!(queue_name: "default")
    SolidQueue::ReadyExecution.create!(queue_name: "mailers")
    SolidQueue::Pause.create!(queue_name: "mailers")
    assert_equal 1, Skaler::ReadyJobsSensor.new.take_measurement
  end

  test "accepts a custom model" do
    custom = Class.new(SolidQueue::ReadyExecution) do
      def self.all = FakeActiveRecord::Relation.new(SolidQueue::ReadyExecution.rows.first(1))
    end
    2.times { SolidQueue::ReadyExecution.create!(queue_name: "default") }
    assert_equal 1, Skaler::ReadyJobsSensor.new(model: custom).take_measurement
  end
end
