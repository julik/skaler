require "test_helper"

class Skaler::TraceTest < Skaler::TestCase
  test "starts empty" do
    trace = Skaler::Trace.new
    assert_empty trace.snapshots
    assert_equal 0, trace.size
  end

  test "records snapshots with time" do
    trace = Skaler::Trace.new
    trace.record(0.0, {instances: 5, utilization: 0.7})
    trace.record(60.0, {instances: 7, utilization: 0.85})

    assert_equal 2, trace.size
    assert_equal 0.0, trace.snapshots[0][:t]
    assert_equal 5, trace.snapshots[0][:instances]
    assert_equal 60.0, trace.snapshots[1][:t]
    assert_equal 7, trace.snapshots[1][:instances]
  end

  test "snapshot contains all expected fields" do
    trace = Skaler::Trace.new
    metrics = {
      utilization: 0.7,
      raw_utilization: 0.68,
      error: 0.0,
      p: 0.0,
      i: 0.02,
      d: -0.01,
      output: 0.01,
      instances: 5,
      active_workers: 5,
      busy_threads: 12,
      free_threads: 13,
      ready_queue_depth: 3,
      completed_since_last: 42,
      arrivals_since_last: 45,
      scale_command: nil,
      pg_headroom: 20,
      redis_headroom: 30,
      instance_minutes: 5.0,
      cumulative_instance_minutes: 25.0
    }

    trace.record(120.0, metrics)
    snapshot = trace.snapshots.first

    assert_equal 120.0, snapshot[:t]
    metrics.each do |key, value|
      if value.nil?
        assert_nil snapshot[key], "Expected #{key} to be nil"
      else
        assert_equal value, snapshot[key], "Expected #{key} to be #{value}"
      end
    end
  end
end
