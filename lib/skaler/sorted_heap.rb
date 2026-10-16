# Binary min-heap priority queue. Stores items with a priority value and
# returns them in ascending priority order.
#
# O(log n) push/pop — replaces the previous sorted-array implementation
# which was O(n) due to Array#insert / Array#shift element shifting.
#
# @example Basic usage
#   heap = Skaler::SortedHeap.new
#   heap.put("urgent", 1)
#   heap.put("normal", 5)
#   heap.put("low", 10)
#   heap.remove(1)  # => ["urgent"]
#
# @example Priority-cutoff removal with filter
#   heap.remove_having_priority(10, 5) { |item| item.ready? }
class Skaler::SortedHeap
  Tuple = Struct.new(:value, :priority)

  def initialize
    @data = []
  end

  # @return [Integer] number of items stored
  def length
    @data.length
  end

  # Places the item in the heap at the given priority.
  # O(log n).
  #
  # @param item [Object] the object to store
  # @param at_priority [Comparable] priority value (lower = returned first).
  #   Can be a Numeric or an Array (e.g. `[time, seq]`) — anything responding to `<=>`.
  def put(item, at_priority)
    tuple = Tuple.new(item, at_priority)
    @data << tuple
    sift_up(@data.length - 1)
  end

  # Returns the first (lowest-priority) item without removing it.
  #
  # @return [Object, nil]
  def first
    @data.first&.value
  end

  # Takes `n` first items off the heap. Order among same-priority items is undefined.
  # O(n log size).
  #
  # @param n [Integer] max items to remove
  # @return [Array<Object>] removed items (may be shorter than n)
  def remove(n)
    result = []
    n.times do
      break if @data.empty?
      result << pop_min
    end
    result
  end

  # Counts how many items have priority at or below the cutoff, without removing them.
  # O(size) — scans the full heap. Not on the simulator hot path.
  #
  # @param priority_at_or_below [Comparable] cutoff priority
  # @return [Integer]
  def peek_backlog(priority_at_or_below)
    @data.count { |t| (t.priority <=> priority_at_or_below) <= 0 }
  end

  # Returns items with priority at or below the cutoff, without removing them.
  # O(size).
  #
  # @param priority_at_or_below [Comparable] cutoff priority
  # @return [Array<Object>]
  def peek(priority_at_or_below)
    @data.select { |t| (t.priority <=> priority_at_or_below) <= 0 }
      .sort_by(&:priority)
      .map(&:value)
  end

  # Removes up to `at_most_n` items with priority at or below the cutoff.
  # An optional filter block can reject individual items (they stay in the heap).
  # O(size log size) — not on the simulator hot path.
  #
  # @param at_most_n [Integer] max items to remove
  # @param priority_at_or_below [Comparable] cutoff priority
  # @yield [item] optional filter — return truthy to remove, falsy to skip
  # @return [Array<Object>] removed items
  def remove_having_priority(at_most_n, priority_at_or_below, &filter_proc)
    # Collect matching indices sorted by priority (so we remove lowest first)
    candidates = []
    @data.each_with_index do |t, i|
      candidates << i if (t.priority <=> priority_at_or_below) <= 0
    end
    candidates.sort_by! { |i| @data[i].priority }

    removed = []
    remove_indices = []
    candidates.each do |i|
      break if removed.length == at_most_n
      if filter_proc.nil? || filter_proc.call(@data[i].value)
        removed << @data[i].value
        remove_indices << i
      end
    end

    # Remove from end to front so indices stay valid
    remove_indices.sort.reverse_each { |i| delete_at(i) }
    removed
  end

  private

  # Pop the minimum element. O(log n).
  def pop_min
    return nil if @data.empty?
    min = @data.first.value
    last = @data.pop
    if @data.any?
      @data[0] = last
      sift_down(0)
    end
    min
  end

  # Delete element at arbitrary index. O(log n).
  def delete_at(i)
    return if i >= @data.length
    last = @data.pop
    return if i == @data.length # was the last element
    @data[i] = last
    sift_up(i)
    sift_down(i)
  end

  def sift_up(i)
    while i > 0
      parent = (i - 1) >> 1
      break if (@data[parent].priority <=> @data[i].priority) <= 0
      @data[parent], @data[i] = @data[i], @data[parent]
      i = parent
    end
  end

  def sift_down(i)
    size = @data.length
    loop do
      smallest = i
      left = (i << 1) + 1
      right = left + 1

      if left < size && (@data[left].priority <=> @data[smallest].priority) < 0
        smallest = left
      end
      if right < size && (@data[right].priority <=> @data[smallest].priority) < 0
        smallest = right
      end

      break if smallest == i
      @data[i], @data[smallest] = @data[smallest], @data[i]
      i = smallest
    end
  end
end
