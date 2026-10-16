require "test_helper"

class Skaler::ArrivalProcessTest < Skaler::TestCase
  test "poisson mode generates events at approximately the right rate" do
    rng = Random.new(42)
    queue = Skaler::EventQueue.new
    rate_per_minute = 60.0 # 1 per second

    ap = Skaler::ArrivalProcess.new(
      mode: :poisson,
      rate_per_minute: rate_per_minute,
      default_type: :test_job,
      max_time: 600.0, # 10 minutes
      rng: rng
    )
    ap.seed_events(queue)

    # Expect roughly 600 events (1/sec * 600 sec) with some variance
    assert_in_delta 600, queue.size, 100
  end

  test "poisson mode produces deterministic results with same seed" do
    events1 = generate_poisson_events(seed: 42)
    events2 = generate_poisson_events(seed: 42)

    assert_equal events1.size, events2.size
    events1.zip(events2).each do |e1, e2|
      assert_equal e1, e2
    end
  end

  test "poisson mode events are all job_arrived type" do
    events = generate_poisson_events(seed: 42)
    events.each do |time, type, payload|
      assert_equal :job_arrived, type
      assert_equal :test_job, payload[:job_type]
    end
  end

  test "poisson mode events are in time order" do
    events = generate_poisson_events(seed: 42)
    times = events.map(&:first)
    assert_equal times.sort, times
  end

  test "scheduled mode spreads events within minute buckets" do
    queue = Skaler::EventQueue.new
    schedule = [
      [0.0, 3, :type_a],
      [10.0, 2, :type_b],
      [100.0, 1, nil] # nil falls back to default_type
    ]

    ap = Skaler::ArrivalProcess.new(
      mode: :scheduled,
      default_type: :default_job,
      max_time: 200.0,
      rng: Random.new(1),
      schedule: schedule,
      burst_ratio: 0.0
    )
    ap.seed_events(queue)

    assert_equal 6, queue.size

    # Drain all events and verify counts/types/time ranges
    events = 6.times.map { queue.pop }
    by_type = events.group_by { |_, _, payload| payload[:job_type] }

    assert_equal 3, by_type[:type_a].size
    assert_equal 2, by_type[:type_b].size
    assert_equal 1, by_type[:default_job].size

    # type_a events within [0, 60) bucket
    by_type[:type_a].each { |time, _, _|
      assert_operator time, :>=, 0.0
      assert_operator time, :<, 60.0
    }
    # type_b events within [10, 70) bucket
    by_type[:type_b].each { |time, _, _|
      assert_operator time, :>=, 10.0
      assert_operator time, :<, 70.0
    }
    # default_job within [100, 160) bucket
    by_type[:default_job].each { |time, _, _|
      assert_operator time, :>=, 100.0
      assert_operator time, :<, 160.0
    }

    # All are :job_arrived events
    events.each { |_, type, _| assert_equal :job_arrived, type }
  end

  test "scheduled mode with burst ratio concentrates arrivals" do
    queue = Skaler::EventQueue.new
    schedule = [[0.0, 100, :type_a]]

    ap = Skaler::ArrivalProcess.new(
      mode: :scheduled,
      default_type: :type_a,
      max_time: 200.0,
      rng: Random.new(42),
      schedule: schedule,
      burst_ratio: 1.0
    )
    ap.seed_events(queue)

    assert_equal 100, queue.size

    # All 100 should land within a ~3s window
    times = 100.times.map { queue.pop[0] }
    spread = times.max - times.min
    assert spread < 5.0, "Expected burst arrivals within ~3s window, got spread=#{spread.round(2)}s"
  end

  test "compound_poisson mode generates bulk_arrival events" do
    rng = Random.new(42)
    queue = Skaler::EventQueue.new

    ap = Skaler::ArrivalProcess.new(
      mode: :compound_poisson,
      rate_per_minute: 10.0,
      default_type: :batch_job,
      max_time: 60.0,
      rng: rng,
      batch_size: 5
    )
    ap.seed_events(queue)

    event_count = queue.size
    assert event_count > 0

    _, type, payload = queue.pop
    assert_equal :bulk_arrival, type
    assert_equal :batch_job, payload[:job_type]
    assert_equal 5, payload[:count]
  end

  test "poisson mode with type_weights distributes arrivals proportionally" do
    rng = Random.new(42)
    queue = Skaler::EventQueue.new
    weights = {type_a: 0.7, type_b: 0.2, type_c: 0.1}

    ap = Skaler::ArrivalProcess.new(
      mode: :poisson,
      rate_per_minute: 600.0,
      default_type: :type_a,
      max_time: 600.0,
      rng: rng,
      type_weights: weights
    )
    ap.seed_events(queue)

    counts = Hash.new(0)
    while (event = queue.pop)
      _, _, payload = event
      counts[payload[:job_type]] += 1
    end

    total = counts.values.sum.to_f
    # type_a should be ~70% of arrivals
    assert_in_delta 0.7, counts[:type_a] / total, 0.05
    # type_b should be ~20%
    assert_in_delta 0.2, counts[:type_b] / total, 0.05
    # type_c should be ~10%
    assert_in_delta 0.1, counts[:type_c] / total, 0.05
  end

  test "raises on unknown mode" do
    ap = Skaler::ArrivalProcess.new(
      mode: :unknown,
      default_type: :test,
      max_time: 10.0,
      rng: Random.new(1)
    )

    assert_raises(ArgumentError) { ap.seed_events(Skaler::EventQueue.new) }
  end

  private

  def generate_poisson_events(seed:)
    rng = Random.new(seed)
    queue = Skaler::EventQueue.new
    ap = Skaler::ArrivalProcess.new(
      mode: :poisson,
      rate_per_minute: 60.0,
      default_type: :test_job,
      max_time: 120.0,
      rng: rng
    )
    ap.seed_events(queue)

    events = []
    while (event = queue.pop)
      events << event
    end
    events
  end
end
