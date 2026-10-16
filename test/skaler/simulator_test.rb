require "test_helper"

class Skaler::SimulatorTest < Skaler::TestCase
  test "sustained load converges to stable instance count" do
    trace = run_simulation(
      rate_per_minute: 200,
      max_time: 3600,
      spawn_rules: []
    )

    # Should have produced snapshots
    assert trace.size > 10

    # Last quarter should be relatively stable (instances don't swing wildly)
    quarter = trace.size / 4
    last_quarter = trace.last(quarter)
    instance_counts = last_quarter.map { |s| s[:instances] }
    range = instance_counts.max - instance_counts.min
    assert range <= 10, "Instance count should stabilize; range was #{range}"
  end

  test "cascade amplification requires more workers than non-cascading load" do
    # Without cascading
    trace_no_cascade = run_simulation(
      rate_per_minute: 300,
      max_time: 1800,
      spawn_rules: []
    )

    # With cascading (80% spawn probability)
    trace_cascade = run_simulation(
      rate_per_minute: 300,
      max_time: 1800,
      spawn_rules: [{probability: 0.8, child_type: :child_job, count: 1}]
    )

    max_no_cascade = trace_no_cascade.map { |s| s[:instances] }.max
    max_cascade = trace_cascade.map { |s| s[:instances] }.max
    assert max_cascade > max_no_cascade,
      "Cascading load (max=#{max_cascade}) should need more workers than non-cascading (max=#{max_no_cascade})"
  end

  test "burst recovery — system scales up then back down" do
    # Schedule a burst of 500 jobs at t=300, plus a low baseline to keep system alive
    schedule = [[300.0, 500, :process_email]]
    # Add a trickle of arrivals so the system isn't completely idle before the burst
    (0..1800).step(10) { |t| schedule << [t.to_f, 1, :process_email] }

    sim = Skaler::Simulator.new(
      job_types: simple_job_types,
      arrival_process: {mode: :scheduled, default_type: :process_email, schedule: schedule},
      pid_config: {kp: 0.8, ki: 0.1, kd: 0.35, setpoint: 0.7, deadband: 0.05},
      pool_config: {initial_workers: 2, threads_per_worker: 5, min_workers: 2, max_workers: 30},
      constraints: {pg_max: 2000, redis_max: 5000, pg_pool_size: 7, redis_pool_per_worker: 10},
      timing: {autoscaler_interval: 15, boot_lag_seconds: 30, cooldown_seconds: 10, max_time: 1800},
      smoothing_alpha: 0.5,
      metric_mode: "pressure",
      random_seed: 42
    )
    trace = sim.run

    instances_over_time = trace.map { |s| s[:instances] }
    peak = instances_over_time.max
    final = instances_over_time.last

    assert peak > 2, "Should have scaled up from burst; peak was #{peak}"
    assert final < peak, "Should have scaled back down; final=#{final}, peak=#{peak}"
  end

  test "boot lag prevents premature rescaling" do
    trace = run_simulation(
      rate_per_minute: 500,
      max_time: 1200,
      boot_lag_seconds: 120,
      spawn_rules: []
    )

    scale_ups = trace.select { |s| s[:scale_command]&.start_with?("+") }
    # With high load, there should be at least one scale-up
    assert scale_ups.size >= 1, "Should have at least one scale-up with 500 jobs/min"

    # No second scale-up should happen while boots are pending (boot_lag=120s)
    if scale_ups.size >= 2
      times = scale_ups.map { |s| s[:t] }
      gaps = times.each_cons(2).map { |a, b| b - a }
      gaps.each do |gap|
        assert gap >= 120, "Gap between scale-ups should respect boot lag; got #{gap}s"
      end
    end
  end

  test "sub-second jobs drain faster than multi-second jobs" do
    trace_fast = run_simulation(
      rate_per_minute: 300,
      max_time: 1200,
      duration: ->(rng) { rng.rand(0.05..0.2) },
      spawn_rules: []
    )

    trace_slow = run_simulation(
      rate_per_minute: 300,
      max_time: 1200,
      duration: ->(rng) { rng.rand(3.0..8.0) },
      spawn_rules: []
    )

    avg_queue_fast = trace_fast.map { |s| s[:ready_queue_depth] }.sum.to_f / trace_fast.size
    avg_queue_slow = trace_slow.map { |s| s[:ready_queue_depth] }.sum.to_f / trace_slow.size

    assert avg_queue_fast < avg_queue_slow,
      "Fast jobs (avg queue=#{avg_queue_fast.round(1)}) should have shorter queues than slow (#{avg_queue_slow.round(1)})"
  end

  test "deterministic replay — same seed produces identical trace" do
    trace1 = run_simulation(rate_per_minute: 200, max_time: 600, spawn_rules: [], seed: 123)
    trace2 = run_simulation(rate_per_minute: 200, max_time: 600, spawn_rules: [], seed: 123)

    assert_equal trace1.size, trace2.size
    trace1.zip(trace2).each_with_index do |(s1, s2), i|
      assert_equal s1, s2, "Snapshot #{i} differs between runs"
    end
  end

  test "autoscaler tick fires at expected intervals" do
    trace = run_simulation(
      rate_per_minute: 100,
      max_time: 600,
      autoscaler_interval: 30,
      spawn_rules: []
    )

    times = trace.map { |s| s[:t] }
    # Should start at 0 and increment by 30
    assert_equal 0.0, times.first
    times.each_cons(2) do |a, b|
      assert_in_delta 30.0, b - a, 0.001
    end
  end

  test "cumulative instance_minutes increases monotonically" do
    trace = run_simulation(rate_per_minute: 200, max_time: 1200, spawn_rules: [])

    costs = trace.map { |s| s[:cumulative_instance_minutes] }
    costs.each_cons(2) do |a, b|
      assert b >= a, "Cumulative cost must be monotonically increasing"
    end
    assert costs.last > 0, "Should accumulate some cost"
  end

  test "accepts pre-built ArrivalProcess instance" do
    rng = Random.new(42)
    arrival = Skaler::ArrivalProcess.new(
      mode: :poisson,
      rate_per_minute: 100,
      default_type: :process_email,
      max_time: 300,
      rng: rng
    )

    sim = Skaler::Simulator.new(
      job_types: simple_job_types,
      arrival_process: arrival,
      pid_config: {kp: 0.5, ki: 0.1, kd: 0.2, setpoint: 0.7, deadband: 0.1},
      pool_config: {initial_workers: 2, threads_per_worker: 5, min_workers: 2, max_workers: 20},
      constraints: {pg_max: 2000, redis_max: 5000, pg_pool_size: 7, redis_pool_per_worker: 10},
      timing: {autoscaler_interval: 60, boot_lag_seconds: 60, cooldown_seconds: 15, max_time: 300},
      random_seed: 42
    )
    trace = sim.run
    assert trace.size > 0
  end

  private

  def simple_job_types(duration: nil, spawn_rules: [])
    child_type = Skaler::JobType.new(
      name: :child_job,
      duration: duration || ->(rng) { rng.rand(1.0..5.0) },
      spawn_rules: []
    )
    parent_type = Skaler::JobType.new(
      name: :process_email,
      duration: duration || ->(rng) { rng.rand(1.0..5.0) },
      spawn_rules: spawn_rules
    )
    {process_email: parent_type, child_job: child_type}
  end

  def run_simulation(
    rate_per_minute:, max_time:, spawn_rules:,
    seed: 42, duration: nil, boot_lag_seconds: 60, autoscaler_interval: 60
  )
    Skaler::Simulator.new(
      job_types: simple_job_types(duration: duration, spawn_rules: spawn_rules),
      arrival_process: {mode: :poisson, rate_per_minute: rate_per_minute, default_type: :process_email},
      pid_config: {kp: 0.8, ki: 0.1, kd: 0.35, setpoint: 0.7, deadband: 0.1},
      pool_config: {initial_workers: 2, threads_per_worker: 5, min_workers: 2, max_workers: 60},
      constraints: {pg_max: 2000, redis_max: 5000, pg_pool_size: 7, redis_pool_per_worker: 10},
      timing: {
        autoscaler_interval: autoscaler_interval,
        boot_lag_seconds: boot_lag_seconds,
        cooldown_seconds: 15,
        max_time: max_time
      },
      random_seed: seed
    ).run
  end
end
