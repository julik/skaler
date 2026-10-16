require "test_helper"

class Skaler::SortedHeapTest < Skaler::TestCase
  setup do
    @heap = Skaler::SortedHeap.new
    @heap.put("a", 1)
    @heap.put("d", 3)
    @heap.put("b", 1)
    @heap.put("d", 1)
    @heap.put("c", 1)
    @heap.put("f", 3)
    @heap.put("g", 3)
    @heap.put("e", 3)
  end

  test "removes nothing when below cutoff" do
    assert_same_set [], @heap.remove_having_priority(4, -5)
    assert_same_set [], @heap.remove_having_priority(4, 0)
  end

  test "removes without priority" do
    assert_same_set ["a", "b", "c", "d"], @heap.remove(4)
  end

  test "returns length" do
    assert_equal 8, @heap.length
  end

  test "removes items at cutoff" do
    assert_same_set ["a", "b", "c", "d"], @heap.remove_having_priority(4, 1)
  end

  test "allows backlog peek" do
    assert_equal 4, @heap.peek_backlog(1)
    assert_equal 8, @heap.peek_backlog(999)
  end

  test "removes items above cutoff" do
    assert_same_set ["a", "b", "c", "d"], @heap.remove_having_priority(4, 2)
  end

  test "removes items inserted later" do
    @heap.put("m", 0)
    @heap.put("n", 0)
    @heap.put("y", 5)
    assert_same_set ["m", "n"], @heap.remove_having_priority(4, 0)
  end

  test "removes all items even if an item with lower priority is added" do
    @heap.put("y", 5)
    @heap.put("p", -12)
    assert_same_set ["b", "d", "c", "a", "e", "f", "g", "y", "p"], @heap.remove_having_priority(100, 5)
  end

  test "peek returns items without removing" do
    assert_same_set [], @heap.peek(-100)
    assert_same_set [], @heap.peek(0)
    assert_same_set ["a", "b", "d", "c"], @heap.peek(1)
    assert_same_set ["a", "b", "d", "c", "f", "g", "e"], @heap.peek(42)
  end

  test "removes only items of matching priority or lower" do
    @heap.put("y", 5)
    @heap.put("p", -12)
    assert_same_set ["p", "b", "d", "c", "a"], @heap.remove_having_priority(10, 2)
  end

  test "supports infinity priority" do
    @heap.put("y", Float::INFINITY)
    @heap.put("z", 7)
    assert_same_set ["b", "d", "c", "a", "f", "e", "g", "z"], @heap.remove_having_priority(20, 8)
    assert_same_set ["y"], @heap.remove(1)
  end

  test "allows removal using infinity as cutoff" do
    @heap.put("y", Float::INFINITY)
    @heap.put("w", Float::INFINITY)
    assert_same_set ["a", "b", "d", "c", "f", "g", "e", "y", "w"], @heap.remove_having_priority(20, Float::INFINITY)
  end

  test "returns items and removes them from the queue" do
    a = @heap.remove_having_priority(2, 200)
    b = @heap.remove_having_priority(2, 200)
    c = @heap.remove_having_priority(2, 200)
    d = @heap.remove_having_priority(3, 200)
    e = @heap.remove_having_priority(3, 200)

    assert_equal 2, a.length
    assert_equal 2, b.length
    assert_equal 2, c.length
    assert_equal 2, d.length
    assert_equal 0, e.length
  end

  test "removes no items when filter proc returns false" do
    removed = @heap.remove_having_priority(100, 100) { |_| false }
    assert_same_set [], removed
  end

  test "removes items matching filter" do
    removed = @heap.remove_having_priority(100, 100) { |letter| letter == "b" || letter == "f" }
    assert_same_set ["b", "f"], removed
  end

  test "removes items matching filter honoring at_most_n" do
    removed = @heap.remove_having_priority(2, 100) { |letter| letter == "b" || letter == "f" }
    assert_same_set ["b", "f"], removed
  end

  test "removes all items when filter proc returns true" do
    removed = @heap.remove_having_priority(100, 100) { |_| true }
    assert_same_set ["a", "b", "d", "c", "f", "g", "e"], removed
  end

  test "removes the item with highest priority honoring the limit" do
    @heap.put("p", -12)
    assert_same_set ["p"], @heap.remove_having_priority(10, -12)
  end

  private

  def assert_same_set(expected, actual)
    assert_equal Set.new(expected), Set.new(actual)
  end
end
