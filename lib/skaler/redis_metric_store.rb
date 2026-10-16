# Redis-backed metric store using a sorted set for time-series data.
#
# Each measurement is stored as a JSON-serialized member in a sorted set,
# scored by timestamp. Uses the Redis server's TIME command so that
# timestamps are consistent across processes and survive restarts.
# Auto-prunes entries older than 1800 seconds on each record.
#
# @example
#   store = Skaler::RedisMetricStore.new(redis: Redis.new, key_prefix: "skaler:metrics")
#   store.record(utilization: 0.7, ready_jobs: 5)
#   store.recall(over_last: 300) # => last 5 minutes
class Skaler::RedisMetricStore < Skaler::MetricStore
  MAX_AGE = 1800 # seconds

  CONTROLLER_STATE_MAX_HISTORY = 60 # Cap signal history entries
  CONTROLLER_STATE_TTL = 3600 # 1 hour

  # @param redis [Redis] Redis client
  # @param key_prefix [String] Redis key prefix for the sorted set
  def initialize(redis:, key_prefix: "skaler:metrics")
    @redis = redis
    @key = "#{key_prefix}:timeseries"
    @state_key = "#{key_prefix}:controller_state"
  end

  # @return [Float] current time from the Redis server (seconds + microseconds)
  def now
    seconds, microseconds = @redis.time
    seconds + (microseconds / 1_000_000.0)
  end

  # Record measurements as a JSON member scored by current time.
  #
  # @param measurements [Hash{Symbol => Numeric}]
  def record(measurements)
    t = now
    entry = measurements.merge(t: t)
    @redis.zadd(@key, t, entry.to_json)
    prune!(now: t)
    @redis.expire(@key, MAX_AGE)
  end

  # Recall entries within the given time window.
  #
  # @param over_last [Numeric] seconds of history
  # @return [Array<Hash>] entries with :t key, oldest first
  def recall(over_last:)
    cutoff = now - over_last
    members = @redis.zrangebyscore(@key, cutoff, "+inf")
    members.map { |m| JSON.parse(m, symbolize_names: true) }
  end

  # @param min_duration [Numeric] required seconds of data
  # @return [Boolean]
  def ready?(min_duration:)
    return true if min_duration <= 0
    oldest = @redis.zrangebyscore(@key, "-inf", "+inf", limit: [0, 1])
    return false if oldest.empty?
    first_entry = JSON.parse(oldest.first, symbolize_names: true)
    (now - first_entry[:t]) >= min_duration
  end

  # @return [Hash, nil] most recent measurement set
  def latest
    newest = @redis.zrevrangebyscore(@key, "+inf", "-inf", limit: [0, 1])
    return nil if newest.empty?
    JSON.parse(newest.first, symbolize_names: true)
  end

  # Persist controller state for cross-process continuity.
  #
  # Stores the full state hash as-is (just like MemoryMetricStore), with the
  # sole exception of trimming signal_history to prevent unbounded growth.
  # The store is a dumb pipe — the controller decides what to persist.
  #
  # @param state [Hash] controller state (smoothed_utilization, signal_history, last_action_at, etc.)
  def save_controller_state(state)
    data = state.dup
    data[:signal_history] = (data[:signal_history] || []).last(CONTROLLER_STATE_MAX_HISTORY)
    @redis.set(@state_key, data.to_json, ex: CONTROLLER_STATE_TTL)
  end

  # Load persisted controller state, or nil if none exists.
  #
  # Deserializes JSON and coerces known numeric fields back to floats
  # (JSON round-trip loses Ruby type info). Unknown fields are passed
  # through as-is.
  #
  # @return [Hash, nil] controller state hash
  def load_controller_state
    json = @redis.get(@state_key)
    return nil unless json

    data = JSON.parse(json, symbolize_names: true)
    # Coerce known fields that need specific types after JSON round-trip
    data[:smoothed_utilization] = data[:smoothed_utilization]&.to_f || 0.0
    data[:signal_history] = (data[:signal_history] || []).map { |e| [e[0].to_f, e[1].to_f] }
    data[:last_action_at] = data[:last_action_at]&.to_f
    data
  rescue JSON::ParserError
    nil
  end

  private

  def prune!(now:)
    cutoff = now - MAX_AGE
    @redis.zremrangebyscore(@key, "-inf", cutoff)
  end
end
