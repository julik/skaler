require "test_helper"

class Skaler::WorkerPoolTest < Skaler::TestCase
  setup do
    @pool = Skaler::WorkerPool.new(worker_count: 3, threads_per_worker: 5)
  end

  test "initial capacity" do
    assert_equal 15, @pool.capacity
    assert_equal 0, @pool.busy_count
    assert_equal 15, @pool.free_count
  end

  test "acquire and release" do
    assert @pool.acquire
    assert_equal 1, @pool.busy_count
    assert_equal 14, @pool.free_count

    @pool.release
    assert_equal 0, @pool.busy_count
    assert_equal 15, @pool.free_count
  end

  test "acquire returns false when full" do
    15.times { assert @pool.acquire }
    refute @pool.acquire
    assert_equal 15, @pool.busy_count
    assert_equal 0, @pool.free_count
  end

  test "release returns false when no busy threads" do
    refute @pool.release
    assert_equal 0, @pool.busy_count
  end

  test "add_workers increases capacity" do
    @pool.add_workers(2)
    assert_equal 5, @pool.worker_count
    assert_equal 25, @pool.capacity
    assert_equal 25, @pool.free_count
  end

  test "remove_workers decreases capacity" do
    @pool.remove_workers(1)
    assert_equal 2, @pool.worker_count
    assert_equal 10, @pool.capacity
  end

  test "remove_workers clamps busy to new capacity" do
    10.times { @pool.acquire }
    assert_equal 10, @pool.busy_count

    @pool.remove_workers(2)
    assert_equal 1, @pool.worker_count
    assert_equal 5, @pool.capacity
    assert_equal 5, @pool.busy_count
  end

  test "remove_workers does not go below zero workers" do
    @pool.remove_workers(100)
    assert_equal 0, @pool.worker_count
    assert_equal 0, @pool.capacity
  end

  test "threads_per_worker is accessible" do
    assert_equal 5, @pool.threads_per_worker
  end
end
