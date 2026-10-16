require "test_helper"

class Skaler::JobTypeTest < Skaler::TestCase
  test "samples duration from distribution using provided RNG" do
    rng = Random.new(42)
    job_type = Skaler::JobType.new(
      name: :test_job,
      duration: ->(r) { r.rand(1.0..5.0) }
    )

    durations = 100.times.map { job_type.sample_duration(rng) }
    assert durations.all? { |d| d.between?(1.0, 5.0) }
    assert durations.uniq.size > 1, "Should produce varied durations"
  end

  test "deterministic duration sampling with same seed" do
    job_type = Skaler::JobType.new(
      name: :test_job,
      duration: ->(r) { r.rand(1.0..10.0) }
    )

    rng1 = Random.new(99)
    rng2 = Random.new(99)
    d1 = 10.times.map { job_type.sample_duration(rng1) }
    d2 = 10.times.map { job_type.sample_duration(rng2) }
    assert_equal d1, d2
  end

  test "roll_cascades returns children based on probability" do
    job_type = Skaler::JobType.new(
      name: :parent,
      duration: ->(r) { 1.0 },
      spawn_rules: [
        {probability: 1.0, child_type: :always_child, count: 2},
        {probability: 0.0, child_type: :never_child, count: 1}
      ]
    )

    rng = Random.new(42)
    cascades = job_type.roll_cascades(rng)

    assert_equal 1, cascades.size
    assert_equal :always_child, cascades[0][:child_type]
    assert_equal 2, cascades[0][:count]
  end

  test "roll_cascades with no spawn rules returns empty" do
    job_type = Skaler::JobType.new(
      name: :leaf,
      duration: ->(r) { 1.0 },
      spawn_rules: []
    )

    rng = Random.new(42)
    assert_empty job_type.roll_cascades(rng)
  end

  test "stores name and spawn_rules" do
    rules = [{probability: 0.5, child_type: :child, count: 1}]
    job_type = Skaler::JobType.new(name: :my_job, duration: ->(r) { 1.0 }, spawn_rules: rules)

    assert_equal :my_job, job_type.name
    assert_equal rules, job_type.spawn_rules
  end
end
