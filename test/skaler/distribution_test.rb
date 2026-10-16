require "test_helper"

class Skaler::DistributionTest < Skaler::TestCase
  test "produces values with correct mean and p90" do
    random = Random.new(42)
    dist = Skaler::Distribution.new(p90: 10.24, mean: 6.07, random: random)
    sample = 10_000.times.map { dist.value }

    calculated_mean = sample.sum / sample.length.to_f
    assert_in_delta 6.07, calculated_mean, 0.5

    calculated_p90 = percentile(0.9, sample)
    assert_in_delta 10.24, calculated_p90, 0.5
  end

  test "all values are positive" do
    random = Random.new(42)
    dist = Skaler::Distribution.new(p90: 2.0, mean: 1.0, random: random)
    sample = 10_000.times.map { dist.value }

    assert sample.all? { |v| v > 0 }, "All sampled values should be positive"
  end

  test "deterministic with same seed" do
    s1 = 100.times.map { Skaler::Distribution.new(mean: 5.0, p90: 8.0, random: Random.new(99)).value }
    s2 = 100.times.map { Skaler::Distribution.new(mean: 5.0, p90: 8.0, random: Random.new(99)).value }
    assert_equal s1, s2
  end

  test "call interface works with external RNG for JobType compatibility" do
    dist = Skaler::Distribution.new(mean: 5.0, p90: 8.0)
    rng = Random.new(42)

    val = dist.call(rng)
    assert val.is_a?(Float)
    assert val > 0
  end

  test "works as a JobType duration" do
    dist = Skaler::Distribution.new(mean: 3.0, p90: 6.0)
    job_type = Skaler::JobType.new(name: :test, duration: dist)

    rng = Random.new(42)
    durations = 100.times.map { job_type.sample_duration(rng) }
    assert durations.all? { |d| d > 0 }

    avg = durations.sum / durations.size
    assert_in_delta 3.0, avg, 1.5
  end

  private

  def percentile(p, sample)
    sample.sort!
    k = (p * (sample.length - 1) + 1).floor - 1
    f = (p * (sample.length - 1) + 1).modulo(1)
    sample[k] + (f * (sample[k + 1] - sample[k]))
  end
end
