# Abstract base class for time-series metric storage.
#
# A MetricStore records measurements at each tick and supports duration-based
# recall for computing signal history. Implementations provide different
# backends (in-memory for simulation, Redis for production).
#
# @example
#   store = Skaler::MemoryMetricStore.new(clock: -> { Time.now.to_f })
#   store.record(utilization: 0.7, ready_jobs: 5)
#   store.recall(over_last: 300) # => last 5 minutes of measurements
#   store.ready?(min_duration: 60) # => true if ≥60s of data
class Skaler::MetricStore
  # @return [Float] current time according to the store's clock
  def now
    raise NotImplementedError
  end

  # Record a set of measurements at the current time.
  #
  # @param measurements [Hash{Symbol => Numeric}] sensor readings keyed by name
  def record(measurements)
    raise NotImplementedError
  end

  # Recall measurements recorded within the given duration.
  #
  # @param over_last [Numeric] seconds of history to retrieve
  # @return [Array<Hash>] measurements with :t key for timestamp, newest last
  def recall(over_last:)
    raise NotImplementedError
  end

  # Whether enough data has been accumulated for the controller to act.
  #
  # @param min_duration [Numeric] minimum seconds of data required
  # @return [Boolean]
  def ready?(min_duration:)
    raise NotImplementedError
  end

  # The most recent measurement set, or nil if none recorded.
  #
  # @return [Hash, nil]
  def latest
    raise NotImplementedError
  end

  # Persist controller state (signal history + EMA) for cross-process continuity.
  #
  # @param state [Hash] with :smoothed_utilization and :signal_history keys
  def save_controller_state(state)
    raise NotImplementedError
  end

  # Load persisted controller state, or nil if none exists.
  #
  # @return [Hash, nil] with :smoothed_utilization and :signal_history keys
  def load_controller_state
    raise NotImplementedError
  end
end
