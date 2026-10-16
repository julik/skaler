# In-memory metric store backed by a sorted array.
#
# Uses an injectable clock callable for virtual time in simulation.
# Prunes entries older than the recall window on each recall call.
#
# @example
#   t = 0.0
#   store = Skaler::MemoryMetricStore.new(clock: -> { t })
#   store.record(utilization: 0.5, ready_jobs: 3)
#   t = 60.0
#   store.record(utilization: 0.8, ready_jobs: 10)
#   store.recall(over_last: 120) # => both entries
#   store.recall(over_last: 30)  # => only the t=60 entry
class Skaler::MemoryMetricStore < Skaler::MetricStore
  # @param clock [#call] callable returning current time as Float
  def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    @clock = clock
    @entries = [] # [{t: Float, **measurements}]
    @controller_state = nil
  end

  # @return [Float] current time from the injectable clock
  def now
    @clock.call
  end

  # Record measurements at current clock time.
  #
  # @param measurements [Hash{Symbol => Numeric}]
  def record(measurements)
    @entries << measurements.merge(t: now)
  end

  # Recall entries within the given time window, pruning older entries.
  #
  # @param over_last [Numeric] seconds of history
  # @return [Array<Hash>] entries with :t key, oldest first
  def recall(over_last:)
    cutoff = now - over_last
    @entries.reject! { |e| e[:t] < cutoff }
    @entries.dup
  end

  # @param min_duration [Numeric] required seconds of data
  # @return [Boolean]
  def ready?(min_duration:)
    return true if min_duration <= 0
    return false if @entries.empty?
    (now - @entries.first[:t]) >= min_duration
  end

  # @return [Hash, nil] most recent measurement set
  def latest
    @entries.last
  end

  # @param state [Hash]
  def save_controller_state(state)
    @controller_state = state
  end

  # @return [Hash, nil]
  def load_controller_state
    @controller_state
  end
end
