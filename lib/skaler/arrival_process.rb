# Generates job arrival events for the discrete-event simulator.
#
# Supports three modes:
# - **Poisson**: Exponential inter-arrival times at a given rate per minute
# - **Scheduled**: Deterministic replay from an array of `[time, count, job_type]` tuples
# - **Compound Poisson**: Each Poisson arrival spawns N jobs (models batch ingress)
#
# All modes use a seeded RNG for determinism. Arrival events are pre-generated at
# init and pushed onto the event queue.
#
# @example Poisson arrivals
#   ap = Skaler::ArrivalProcess.new(
#     mode: :poisson, rate_per_minute: 730,
#     default_type: :process_email, max_time: 7200, rng: Random.new(42)
#   )
#   ap.seed_events(event_queue)
#
# @example Weighted multi-type arrivals (from production profile)
#   ap = Skaler::ArrivalProcess.new(
#     mode: :poisson, rate_per_minute: 2500,
#     default_type: :sync_mailbox, max_time: 7200, rng: Random.new(42),
#     type_weights: { sync_mailbox: 0.6, process_webhook: 0.3, fetch_message: 0.1 }
#   )
#   ap.seed_events(event_queue)
class Skaler::ArrivalProcess
  # @param mode [Symbol] :poisson, :scheduled, or :compound_poisson
  # @param rate_per_minute [Float] arrival rate (Poisson/compound modes)
  # @param default_type [Symbol] job type name for arrivals
  # @param max_time [Float] simulation end time in virtual seconds
  # @param rng [Random] seeded RNG
  # @param schedule [Array] for :scheduled mode — `[time, count, job_type]` tuples
  # @param batch_size [Integer] for :compound_poisson — jobs per arrival event
  # @param type_weights [Hash{Symbol => Float}, nil] per-type arrival probability weights
  #   (values should sum to ~1.0). When set, each Poisson arrival picks a type randomly
  #   according to these weights instead of always using default_type.
  # @param burst_ratio [Float] for :scheduled mode — fraction of arrivals (0.0–1.0) that
  #   land in a narrow burst at a random point within the minute bucket. The rest are
  #   spread uniformly. Default 0.7 (70% bursty, 30% uniform). Set to 0.0 for fully
  #   uniform, 1.0 for maximum burstiness.
  def initialize(mode:, default_type:, max_time:, rng:, rate_per_minute: nil, schedule: nil, batch_size: 1, type_weights: nil, burst_ratio: 0.7)
    @mode = mode
    @rate_per_minute = rate_per_minute
    @default_type = default_type
    @max_time = max_time
    @rng = rng
    @schedule = schedule
    @batch_size = batch_size
    @type_weights = type_weights
    @burst_ratio = burst_ratio.clamp(0.0, 1.0)
    @cumulative_weights = build_cumulative_weights(type_weights) if type_weights
  end

  # Pre-generate all arrival events and push them onto the event queue.
  #
  # @param event_queue [Skaler::EventQueue]
  def seed_events(event_queue)
    case @mode
    when :poisson
      seed_poisson(event_queue, batch_size: 1)
    when :compound_poisson
      seed_poisson(event_queue, batch_size: @batch_size)
    when :scheduled
      seed_scheduled(event_queue)
    else
      raise ArgumentError, "Unknown arrival mode: #{@mode}"
    end
  end

  private

  def seed_poisson(event_queue, batch_size:)
    return if @rate_per_minute.to_f <= 0

    rate_per_second = @rate_per_minute / 60.0
    t = 0.0
    while t < @max_time
      # Exponential inter-arrival: -ln(U) / λ
      inter_arrival = -Math.log(@rng.rand) / rate_per_second
      t += inter_arrival
      break if t >= @max_time

      job_type = pick_type
      if batch_size > 1
        event_queue.push(t, :bulk_arrival, {job_type: job_type, count: batch_size})
      else
        event_queue.push(t, :job_arrived, {job_type: job_type})
      end
    end
  end

  # Spread scheduled arrivals within each 60s bucket using a mix of burst
  # and uniform placement. The burst portion lands in a narrow ~3s window
  # at a random offset within the minute, simulating batch triggers (e.g.
  # pubsub pull, cron fire). The uniform portion fills the rest of the minute.
  def seed_scheduled(event_queue)
    @schedule.each do |time, count, job_type|
      type = job_type || @default_type
      burst_count = (count * @burst_ratio).round
      uniform_count = count - burst_count

      # Burst: narrow window (~3s) at a random offset within the minute
      if burst_count > 0
        burst_center = time + @rng.rand * 60.0
        burst_count.times do
          # Gaussian spread around the center, σ ≈ 1.5s
          offset = @rng.rand * 3.0 - 1.5  # simple uniform ±1.5s for speed
          event_queue.push(burst_center + offset, :job_arrived, {job_type: type})
        end
      end

      # Uniform: spread evenly across the full minute
      uniform_count.times do
        event_queue.push(time + @rng.rand * 60.0, :job_arrived, {job_type: type})
      end
    end
  end

  # Pick a job type for this arrival. Uses weighted random selection when
  # type_weights are configured, otherwise returns the default type.
  #
  # @return [Symbol] job type name
  def pick_type
    return @default_type unless @cumulative_weights

    r = @rng.rand
    @cumulative_weights.each do |type, threshold|
      return type if r < threshold
    end
    @default_type # fallback for floating-point edge cases
  end

  # Pre-compute a cumulative distribution from weight hash for O(n) sampling.
  #
  # @param weights [Hash{Symbol => Float}] type → probability weight
  # @return [Array<Array(Symbol, Float)>] sorted [type, cumulative_threshold] pairs
  def build_cumulative_weights(weights)
    total = weights.values.sum.to_f
    cumulative = 0.0
    weights.sort_by { |_, w| -w }.map do |type, weight|
      cumulative += weight / total
      [type, cumulative]
    end
  end
end
