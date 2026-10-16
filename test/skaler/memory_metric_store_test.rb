require "test_helper"

class Skaler::MemoryMetricStoreTest < Skaler::TestCase
  setup do
    @time = 0.0
    @store = Skaler::MemoryMetricStore.new(clock: -> { @time })
  end

  test "now returns current clock value" do
    @time = 42.5
    assert_equal 42.5, @store.now
  end

  test "record and latest" do
    @store.record(utilization: 0.5, ready_jobs: 3)
    latest = @store.latest
    assert_equal 0.5, latest[:utilization]
    assert_equal 3, latest[:ready_jobs]
    assert_equal 0.0, latest[:t]
  end

  test "latest returns nil when empty" do
    assert_nil @store.latest
  end

  test "recall returns entries within time window" do
    @store.record(utilization: 0.3)
    @time = 60.0
    @store.record(utilization: 0.5)
    @time = 120.0
    @store.record(utilization: 0.7)

    entries = @store.recall(over_last: 90)
    assert_equal 2, entries.size
    assert_equal 0.5, entries.first[:utilization]
    assert_equal 0.7, entries.last[:utilization]
  end

  test "recall prunes old entries" do
    @store.record(utilization: 0.3)
    @time = 200.0
    @store.record(utilization: 0.7)

    @store.recall(over_last: 60)
    # Now recall all — old entry should have been pruned
    entries = @store.recall(over_last: 300)
    assert_equal 1, entries.size
    assert_equal 0.7, entries.first[:utilization]
  end

  test "ready? with zero min_duration is always true" do
    assert @store.ready?(min_duration: 0)
    assert @store.ready?(min_duration: 0.0)
  end

  test "ready? returns false when empty" do
    refute @store.ready?(min_duration: 10)
  end

  test "ready? returns true when enough data accumulated" do
    @store.record(utilization: 0.5)
    @time = 30.0
    refute @store.ready?(min_duration: 60)
    @time = 60.0
    assert @store.ready?(min_duration: 60)
  end

  test "recall returns entries oldest first" do
    @store.record(utilization: 0.1)
    @time = 10.0
    @store.record(utilization: 0.2)
    @time = 20.0
    @store.record(utilization: 0.3)

    entries = @store.recall(over_last: 100)
    times = entries.map { |e| e[:t] }
    assert_equal [0.0, 10.0, 20.0], times
  end

  test "load_controller_state returns nil when nothing saved" do
    assert_nil @store.load_controller_state
  end

  test "save and load controller state round-trips" do
    history = [[0.1, 100.0], [-0.05, 160.0]]
    @store.save_controller_state(smoothed_utilization: 0.72, signal_history: history)

    loaded = @store.load_controller_state
    assert_equal 0.72, loaded[:smoothed_utilization]
    assert_equal history, loaded[:signal_history]
  end
end
