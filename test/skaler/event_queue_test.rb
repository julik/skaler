require "test_helper"

class Skaler::EventQueueTest < Skaler::TestCase
  setup do
    @queue = Skaler::EventQueue.new
  end

  test "starts empty" do
    assert @queue.empty?
    assert_equal 0, @queue.size
    assert_nil @queue.peek_time
    assert_nil @queue.pop
  end

  test "pops events in time order" do
    @queue.push(10.0, :late, {})
    @queue.push(1.0, :early, {})
    @queue.push(5.0, :middle, {})

    time, type, _payload = @queue.pop
    assert_equal 1.0, time
    assert_equal :early, type

    time, type, _payload = @queue.pop
    assert_equal 5.0, time
    assert_equal :middle, type

    time, type, _payload = @queue.pop
    assert_equal 10.0, time
    assert_equal :late, type
  end

  test "breaks time ties with FIFO order" do
    @queue.push(5.0, :first, {id: 1})
    @queue.push(5.0, :second, {id: 2})
    @queue.push(5.0, :third, {id: 3})

    _, type, _ = @queue.pop
    assert_equal :first, type

    _, type, _ = @queue.pop
    assert_equal :second, type

    _, type, _ = @queue.pop
    assert_equal :third, type
  end

  test "peek_time returns next event time without removing" do
    @queue.push(3.0, :a, {})
    @queue.push(1.0, :b, {})

    assert_equal 1.0, @queue.peek_time
    assert_equal 2, @queue.size
  end

  test "size tracks insertions and removals" do
    @queue.push(1.0, :a, {})
    @queue.push(2.0, :b, {})
    assert_equal 2, @queue.size

    @queue.pop
    assert_equal 1, @queue.size

    @queue.pop
    assert_equal 0, @queue.size
    assert @queue.empty?
  end

  test "handles large number of events efficiently" do
    1000.times { |i| @queue.push(rand * 1000, :event, {i: i}) }
    assert_equal 1000, @queue.size

    prev_time = -1.0
    1000.times do
      time, _type, _payload = @queue.pop
      assert time >= prev_time, "Events must come out in time order"
      prev_time = time
    end
  end

  test "preserves payload through push/pop" do
    payload = {job_type: :process_email, extra: "data"}
    @queue.push(1.0, :job_arrived, payload)
    _, _, returned_payload = @queue.pop
    assert_equal payload, returned_payload
  end

  test "due_count returns number of events at or before the given time" do
    @queue.push(1.0, :a, {})
    @queue.push(1.0, :b, {})
    @queue.push(5.0, :c, {})
    @queue.push(10.0, :d, {})

    assert_equal 0, @queue.due_count(0.5)
    assert_equal 2, @queue.due_count(1.0)
    assert_equal 2, @queue.due_count(3.0)
    assert_equal 3, @queue.due_count(5.0)
    assert_equal 4, @queue.due_count(100.0)
  end

  test "pop_due returns all events at or before the given time in FIFO order" do
    @queue.push(1.0, :first, {id: 1})
    @queue.push(1.0, :second, {id: 2})
    @queue.push(5.0, :third, {id: 3})
    @queue.push(10.0, :fourth, {id: 4})

    batch = @queue.pop_due(1.0)
    assert_equal 2, batch.size
    assert_equal :first, batch[0][1]
    assert_equal :second, batch[1][1]

    # Those events are now removed
    assert_equal 2, @queue.size
    assert_equal 5.0, @queue.peek_time
  end

  test "pop_due returns empty array when nothing is due" do
    @queue.push(10.0, :future, {})
    assert_equal [], @queue.pop_due(5.0)
    assert_equal 1, @queue.size
  end

  test "first accessor on sorted heap" do
    heap = Skaler::SortedHeap.new
    assert_nil heap.first

    heap.put("b", 5)
    heap.put("a", 1)
    assert_equal "a", heap.first
  end
end
