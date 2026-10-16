# Thread slot manager for the discrete-event simulator.
#
# Tracks N worker processes x M threads each as a simple counter of free/busy slots.
# No individual thread modeling — just capacity arithmetic.
#
# @example
#   pool = Skaler::WorkerPool.new(worker_count: 5, threads_per_worker: 5)
#   pool.capacity      # => 25
#   pool.acquire       # => true
#   pool.busy_count    # => 1
#   pool.release
#   pool.add_workers(2) # capacity now 35
class Skaler::WorkerPool
  attr_reader :worker_count, :threads_per_worker

  # @param worker_count [Integer] number of worker processes
  # @param threads_per_worker [Integer] thread slots per worker process
  def initialize(worker_count:, threads_per_worker:)
    @worker_count = worker_count
    @threads_per_worker = threads_per_worker
    @busy = 0
  end

  # @return [Integer] total thread slots (workers x threads)
  def capacity
    @worker_count * @threads_per_worker
  end

  # @return [Integer] currently occupied slots
  def busy_count
    @busy
  end

  # @return [Integer] available slots
  def free_count
    capacity - @busy
  end

  # Acquire a thread slot. Returns false if none available.
  #
  # @return [Boolean]
  def acquire
    return false if @busy >= capacity
    @busy += 1
    true
  end

  # Release a thread slot.
  # Returns false if no busy threads (e.g. job completed on a since-removed worker).
  #
  # @return [Boolean] true if a slot was freed, false if already at zero
  def release
    return false if @busy <= 0
    @busy -= 1
    true
  end

  # Add worker processes, increasing capacity.
  #
  # @param n [Integer] number of workers to add
  def add_workers(n)
    @worker_count += n
  end

  # Remove worker processes, decreasing capacity.
  # If busy count exceeds new capacity, excess threads are forcibly released.
  #
  # @param n [Integer] number of workers to remove
  def remove_workers(n)
    @worker_count = [@worker_count - n, 0].max
    @busy = [@busy, capacity].min
  end
end
