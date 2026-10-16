# Min-heap priority queue for discrete-event simulation, backed by `Skaler::SortedHeap`.
#
# Each event is an `Event` struct stored in the heap with a composite `[time, seq]` priority.
# Ruby arrays compare lexicographically, so same-time events are returned in FIFO insertion
# order — no extra tie-breaking logic needed.
#
# SortedHeap is a binary min-heap: O(log n) push and O(log n) pop.
# `due_count` and `pop_due` are O(n) scans — not used in the simulator hot path.
#
# @example
#   q = Skaler::EventQueue.new
#   q.push(10.0, :job_arrived, { job_type: :process_email })
#   q.push(5.0, :autoscaler_tick, {})
#   q.push(5.0, :job_arrived, { job_type: :summarize })
#
#   q.peek_time            # => 5.0
#   q.due_count(5.0)       # => 2 (both events at t=5)
#   time, type, _ = q.pop  # => [5.0, :autoscaler_tick, {}]  (FIFO within same time)
class Skaler::EventQueue
  Event = Struct.new(:time, :type, :payload)

  def initialize
    @heap = Skaler::SortedHeap.new
    @seq = 0
  end

  # Push an event onto the queue.
  #
  # @param time [Float] virtual time at which the event fires
  # @param type [Symbol] event type (:job_arrived, :job_completed, etc.)
  # @param payload [Hash] event-specific data
  def push(time, type, payload = {})
    event = Event.new(time, type, payload)
    seq = @seq += 1
    @heap.put(event, [time, seq])
  end

  # Pop the next event (lowest time, then FIFO among same-time events).
  #
  # @return [Array(Float, Symbol, Hash)] `[time, type, payload]` or `nil` if empty
  def pop
    events = @heap.remove(1)
    return nil if events.empty?
    event = events.first
    [event.time, event.type, event.payload]
  end

  # Peek at the next event's time without removing it.
  #
  # @return [Float, nil]
  def peek_time
    @heap.first&.time
  end

  # Count how many events are due at or before the given time.
  # Useful for understanding burst size at a given simulation moment.
  #
  # @param time [Float] cutoff time
  # @return [Integer]
  def due_count(time)
    @heap.peek_backlog([time, Float::INFINITY])
  end

  # Pop all events due at or before the given time, in FIFO order.
  #
  # @param time [Float] cutoff time
  # @return [Array<Array(Float, Symbol, Hash)>] list of `[time, type, payload]` tuples
  def pop_due(time)
    count = due_count(time)
    return [] if count == 0
    @heap.remove(count).map { |event| [event.time, event.type, event.payload] }
  end

  # @return [Integer]
  def size
    @heap.length
  end

  # @return [Boolean]
  def empty?
    @heap.length == 0
  end
end
