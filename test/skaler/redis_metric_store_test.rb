require "test_helper"
require_relative "../support/fake_redis"

class Skaler::RedisMetricStoreTest < Skaler::TestCase
  setup do
    @redis = FakeRedis.new
    @store = Skaler::RedisMetricStore.new(redis: @redis, key_prefix: "test:metrics")
  end

  test "record and latest round-trips through JSON" do
    @store.record(utilization: 0.7, ready_jobs: 5)
    latest = @store.latest
    assert_equal 0.7, latest[:utilization]
    assert_equal 5, latest[:ready_jobs]
    assert latest[:t].is_a?(Numeric)
  end

  test "latest returns nil when empty" do
    assert_nil @store.latest
  end

  test "recall returns entries within time window" do
    @store.record(utilization: 0.3)
    sleep 0.05
    @store.record(utilization: 0.7)

    entries = @store.recall(over_last: 10)
    assert_equal 2, entries.size
    assert entries.first[:t] <= entries.last[:t]
  end

  test "ready? with zero min_duration is always true" do
    assert @store.ready?(min_duration: 0)
  end

  test "ready? returns false when empty" do
    refute @store.ready?(min_duration: 10)
  end

  test "now returns redis server time as a float" do
    t = @store.now
    assert t.is_a?(Float)
    assert t > 0
  end

  test "load_controller_state returns nil when nothing saved" do
    assert_nil @store.load_controller_state
  end

  test "save and load controller state round-trips" do
    history = [[0.1, 1000.0], [-0.05, 1060.0]]
    @store.save_controller_state(smoothed_utilization: 0.72, signal_history: history)

    loaded = @store.load_controller_state
    assert_in_delta 0.72, loaded[:smoothed_utilization], 0.001
    assert_equal 2, loaded[:signal_history].size
    assert_in_delta 0.1, loaded[:signal_history][0][0], 0.001
    assert_in_delta(-0.05, loaded[:signal_history][1][0], 0.001)
  end

  test "save and load controller state round-trips last_action_at" do
    @store.save_controller_state(
      smoothed_utilization: 0.72,
      signal_history: [[0.1, 1000.0]],
      last_action_at: 1234567890.5
    )

    loaded = @store.load_controller_state
    assert_in_delta 1234567890.5, loaded[:last_action_at], 0.001
  end

  test "load_controller_state returns nil last_action_at when not set" do
    @store.save_controller_state(smoothed_utilization: 0.5, signal_history: [])

    loaded = @store.load_controller_state
    assert_nil loaded[:last_action_at]
  end

  test "save_controller_state trims history to max" do
    long_history = 100.times.map { |i| [0.01 * i, 1000.0 + i * 60] }
    @store.save_controller_state(smoothed_utilization: 0.5, signal_history: long_history)

    loaded = @store.load_controller_state
    assert_equal Skaler::RedisMetricStore::CONTROLLER_STATE_MAX_HISTORY, loaded[:signal_history].size
  end
end
