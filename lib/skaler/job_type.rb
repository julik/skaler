# Value object describing a class of simulated work.
#
# Each job type has a name, a duration distribution (a callable that takes an RNG),
# and optional spawn rules for modeling job cascading.
#
# @example
#   Skaler::JobType.new(
#     name: :summarize_email,
#     duration: ->(rng) { rng.rand(2.0..8.0) },
#     spawn_rules: [
#       { probability: 0.8, child_type: :send_notification, count: 1 }
#     ]
#   )
class Skaler::JobType
  attr_reader :name, :duration, :spawn_rules

  # @param name [Symbol] unique identifier for this job type
  # @param duration [#call] callable that takes an RNG and returns duration in seconds
  # @param spawn_rules [Array<Hash>] cascading rules, each with :probability, :child_type, :count
  def initialize(name:, duration:, spawn_rules: [])
    @name = name
    @duration = duration
    @spawn_rules = spawn_rules
  end

  # Sample a duration from the distribution.
  #
  # @param rng [Random] seeded RNG for determinism
  # @return [Float] duration in virtual seconds
  def sample_duration(rng)
    @duration.call(rng)
  end

  # Determine which child jobs to spawn after this job completes.
  #
  # @param rng [Random] seeded RNG for determinism
  # @return [Array<Hash>] list of `{ child_type:, count: }` for jobs to spawn
  def roll_cascades(rng)
    @spawn_rules.filter_map do |rule|
      if rng.rand < rule[:probability]
        {child_type: rule[:child_type], count: rule[:count]}
      end
    end
  end
end
