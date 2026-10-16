require "test_helper"

class Skaler::JobProfileTest < Skaler::TestCase
  test "from_csv parses action names into symbolized job types" do
    profile = Skaler::JobProfile.from_csv(csv_path)

    assert_includes profile.job_types.keys, :sync_mailbox_job_perform
    assert_includes profile.job_types.keys, :search_index_document_job_perform
    assert_includes profile.job_types.keys, :digest_mailer_daily_digest
  end

  test "from_csv creates Distribution-based durations in seconds" do
    profile = Skaler::JobProfile.from_csv(csv_path)

    job = profile.job_types[:sync_mailbox_job_perform]
    rng = Random.new(42)

    # Mean is 640ms, samples should cluster around that
    samples = 1000.times.map { job.sample_duration(rng) }
    avg = samples.sum / samples.size

    assert_in_delta 0.64, avg, 0.1, "Mean duration should be ~0.64s (640ms)"
    assert samples.all? { |s| s > 0 }, "All durations should be positive"
  end

  test "type_weights are proportional to throughput counts" do
    profile = Skaler::JobProfile.from_csv(csv_path)

    # SyncMailboxJob has the highest count, should have the highest weight
    weights = profile.type_weights
    top_type = weights.max_by { |_, w| w }.first
    assert_equal :sync_mailbox_job_perform, top_type

    # Weights should sum to ~1.0
    assert_in_delta 1.0, weights.values.sum, 0.001
  end

  test "total_rate_per_minute reflects aggregate throughput" do
    profile = Skaler::JobProfile.from_csv(csv_path)

    # Rate = total_count / (24 * 60)
    assert profile.total_rate_per_minute > 100,
      "Aggregate rate should be substantial; got #{profile.total_rate_per_minute}"
  end

  test "arrival_process_config is valid for Simulator" do
    profile = Skaler::JobProfile.from_csv(csv_path)
    config = profile.arrival_process_config

    assert_equal :poisson, config[:mode]
    assert config[:rate_per_minute] > 0
    assert config[:default_type].is_a?(Symbol)
    assert config[:type_weights].is_a?(Hash)
    assert_equal 12, config[:type_weights].size # one per CSV row
  end

  test "profile can drive a full simulation" do
    profile = Skaler::JobProfile.from_csv(csv_path)

    sim = Skaler::Simulator.new(
      job_types: profile.job_types,
      arrival_process: profile.arrival_process_config,
      pid_config: {kp: 0.8, ki: 0.1, kd: 0.35, setpoint: 0.7, deadband: 0.1},
      pool_config: {initial_workers: 2, threads_per_worker: 5, min_workers: 2, max_workers: 60},
      constraints: {pg_max: 2000, redis_max: 5000, pg_pool_size: 7, redis_pool_per_worker: 10},
      timing: {autoscaler_interval: 60, boot_lag_seconds: 120, cooldown_seconds: 15, max_time: 300},
      random_seed: 42
    )

    trace = sim.run
    assert trace.size > 0, "Simulation should produce snapshots"
    assert trace.last[:instances] >= 2, "Should have at least min_workers instances"
  end

  test "handles custom hours parameter" do
    profile = Skaler::JobProfile.from_csv(csv_path, hours: 12)

    # Same counts over 12 hours means double the rate
    profile_24h = Skaler::JobProfile.from_csv(csv_path, hours: 24)
    assert_in_delta profile.total_rate_per_minute, profile_24h.total_rate_per_minute * 2, 1.0
  end

  test "guards against p90 <= mean" do
    # Create a temporary CSV where p90 < mean (can happen with very low-volume jobs)
    csv_content = <<~CSV
      action,count_24h,mean_ms,p90_ms,p95_ms
      WeirdJob#perform,100,500.0,400.0,450.0
    CSV

    Tempfile.create(["test_profile", ".csv"]) do |f|
      f.write(csv_content)
      f.rewind

      profile = Skaler::JobProfile.from_csv(f.path)
      job = profile.job_types[:weird_job_perform]

      rng = Random.new(42)
      samples = 100.times.map { job.sample_duration(rng) }
      assert samples.all? { |s| s > 0 }, "Should produce valid durations even with p90 < mean"
    end
  end

  private

  def csv_path
    example_path("job_profile_24h.csv")
  end
end
