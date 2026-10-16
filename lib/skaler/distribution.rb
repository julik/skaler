# Generates normally-distributed random values from a mean and p90,
# using the Box-Muller transform. Useful for modeling realistic job durations
# from AppSignal metrics.
#
# Ported from the sked simulator project.
#
# Can be used as a `JobType` duration callable — responds to `call(rng)`.
#
# @example Standalone sampling
#   dist = Skaler::Distribution.new(mean: 6.07, p90: 10.24)
#   dist.value  # => ~6.07 (normally distributed)
#
# @example As a JobType duration
#   Skaler::JobType.new(
#     name: :summarize_email,
#     duration: Skaler::Distribution.new(mean: 6.07, p90: 10.24)
#   )
class Skaler::Distribution
  # @param mean [Numeric] expected mean of the distribution
  # @param p90 [Numeric] 90th percentile value
  # @param random [Random] RNG instance (used by `value`; `call` takes its own RNG)
  def initialize(mean:, p90:, random: Random.new)
    @p90 = p90.to_f
    @mean = mean.to_f
    # For a normal distribution, the 90th percentile is at mean + 1.28 * stddev
    @std_dev = (@p90 - @mean) / 1.28
    @random = random
  end

  # Sample a value using the internal RNG.
  #
  # @return [Float] a normally-distributed sample (clamped to positive)
  def value
    sample(@random)
  end

  # Sample a value using an external RNG. This makes Distribution compatible
  # with the `JobType` duration interface: `duration.call(rng)`.
  #
  # @param rng [Random] RNG to use for this sample
  # @return [Float] a normally-distributed sample (clamped to positive)
  def call(rng)
    sample(rng)
  end

  private

  # Box-Muller transform: generates a standard normal variate from two uniform samples.
  def sample(rng)
    u1 = rng.rand
    u2 = rng.rand
    r = Math.sqrt(-2 * Math.log(u1))
    theta = 2 * Math::PI * u2
    z = r * Math.cos(theta)
    val = @mean + @std_dev * z
    (val < 0) ? @mean - val : val
  end
end
