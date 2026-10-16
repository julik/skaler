require "test_helper"

class Skaler::ControllerTest < Skaler::TestCase
  setup do
    @time = 0.0
    @store = Skaler::MemoryMetricStore.new(clock: -> { @time })
  end

  test "returns 0 during warm-up period" do
    controller = build_controller(warm_up_duration: 60.0)
    @store.record(measurements_at(utilization: 1.0))

    delta = controller.step(@store)
    assert_equal 0, delta
    assert controller.last_state[:warm_up]
  end

  test "returns 0 after warm-up completes with utilization near setpoint" do
    controller = build_controller(warm_up_duration: 60.0, smoothing_alpha: 0.9)
    @store.record(measurements_at(utilization: 0.7))
    @time = 60.0
    @store.record(measurements_at(utilization: 0.7))

    delta = controller.step(@store)
    # At setpoint, output should be in deadband
    assert_equal 0, delta
    refute controller.last_state[:warm_up]
  end

  test "scale up when utilization exceeds setpoint" do
    controller = build_controller(smoothing_alpha: 0.9)

    # Record several ticks of high utilization to build signal
    5.times do |i|
      @time = i * 60.0
      @store.record(measurements_at(utilization: 0.95))
      controller.step(@store)
    end

    # After 5 steps of 95% utilization with high alpha, should want to scale up
    delta = controller.last_state[:delta]
    assert delta > 0, "Expected positive delta after sustained high utilization, got #{delta}"
  end

  test "scale down when utilization is well below setpoint" do
    controller = build_controller(smoothing_alpha: 0.9)

    # Record several ticks of low utilization to build negative integral
    5.times do |i|
      @time = i * 60.0
      @store.record(measurements_at(utilization: 0.1))
      controller.step(@store)
    end

    delta = controller.last_state[:delta]
    assert delta < 0, "Expected negative delta after sustained low utilization, got #{delta}"
  end

  test "deadband prevents action on small deviations" do
    controller = build_controller(smoothing_alpha: 0.9)

    # Utilization at setpoint — within deadband
    3.times do |i|
      @time = i * 60.0
      @store.record(measurements_at(utilization: 0.7))
      controller.step(@store)
    end

    delta = controller.last_state[:delta]
    assert_equal 0, delta
  end

  test "constraint clamping limits scale-up" do
    # Use tight PG cap
    controller = build_controller(pg_cap: 50, smoothing_alpha: 0.9)

    5.times do |i|
      @time = i * 60.0
      @store.record(measurements_at(utilization: 0.95))
      controller.step(@store)
    end

    state = controller.last_state
    # Delta should be clamped by max_additional
    assert state[:delta] <= state[:max_additional],
      "Delta #{state[:delta]} should not exceed max_additional #{state[:max_additional]}"
  end

  test "last_state max_additional reports the binding minimum, not the last constraint's value" do
    # pg_cap 50 with pool_per_worker 7 and 10 active workers clamps the PG
    # constraint to 0 additional instances, while the LAST constraint in the
    # list (MaxInstances, 60 - 10) still reports 50. The reported value must be
    # the min the delta clamp actually enforced, per the dashboard's
    # "min of PG/Redis/Render headroom" description.
    controller = build_controller(pg_cap: 50, smoothing_alpha: 0.9)
    @store.record(measurements_at(utilization: 0.95))
    controller.step(@store)

    assert_equal 0, controller.last_state[:max_additional]
  end

  test "last_state exposes PID terms" do
    controller = build_controller(smoothing_alpha: 0.9)
    @store.record(measurements_at(utilization: 0.9))
    controller.step(@store)

    state = controller.last_state
    assert state.key?(:p)
    assert state.key?(:i)
    assert state.key?(:d)
    assert state.key?(:output)
    assert state.key?(:smoothed_utilization)
    assert state.key?(:raw_utilization)
  end

  test "last_state includes constraint detail keys" do
    controller = build_controller(smoothing_alpha: 0.9)
    @store.record(measurements_at(utilization: 0.9))
    controller.step(@store)

    state = controller.last_state
    assert state.key?(:headroom_pg)
    assert state.key?(:headroom_redis)
    assert state.key?(:max_additional)
  end

  test "pressure mode includes queue factor" do
    controller = build_controller(metric_mode: "pressure", smoothing_alpha: 0.9)
    @store.record(measurements_at(utilization: 0.5, ready_queue_depth: 100, completed_since_last: 10))
    controller.step(@store)

    state = controller.last_state
    # Pressure mode should produce higher raw utilization than pure thread occupancy
    assert state[:raw_utilization] > 0.5, "Pressure mode should add queue factor"
  end

  test "signal history persists across controller instances via store" do
    # First controller builds up signal history
    c1 = build_controller(smoothing_alpha: 0.9)
    3.times do |i|
      @time = i * 60.0
      @store.record(measurements_at(utilization: 0.9))
      c1.step(@store)
    end

    # Verify state was saved to the store
    saved = @store.load_controller_state
    assert saved, "Controller state should be persisted in the store"
    assert saved[:signal_history].size > 0, "Signal history should have entries"
    refute_equal 0.0, saved[:smoothed_utilization], "Smoothed utilization should be non-zero"

    # Second controller instance — should pick up where c1 left off
    c2 = build_controller(smoothing_alpha: 0.9)
    @time = 3 * 60.0
    @store.record(measurements_at(utilization: 0.9))
    c2.step(@store)

    state = c2.last_state
    # I term should be non-zero because signal history was restored
    refute_equal 0.0, state[:i], "I term should be non-zero with restored history"
  end

  test "rapid ticks within MIN_TICK_INTERVAL are skipped" do
    controller = build_controller(smoothing_alpha: 0.9)

    # First tick at t=0
    @store.record(measurements_at(utilization: 0.95))
    controller.step(@store)

    # Second tick only 1s later — should be skipped
    @time = 1.0
    @store.record(measurements_at(utilization: 0.95))
    delta = controller.step(@store)

    assert_equal 0, delta
    assert controller.last_state[:skipped_tick], "Expected tick to be skipped due to rapid interval"
  end

  test "non-monotonic time (dt <= 0) is skipped" do
    controller = build_controller(smoothing_alpha: 0.9)

    @time = 60.0
    @store.record(measurements_at(utilization: 0.95))
    controller.step(@store)

    # Clock goes backwards
    @time = 50.0
    @store.record(measurements_at(utilization: 0.95))
    delta = controller.step(@store)

    assert_equal 0, delta
    assert controller.last_state[:skipped_tick]
    assert controller.last_state[:dt] < 0
  end

  test "tick proceeds after MIN_TICK_INTERVAL has elapsed" do
    controller = build_controller(smoothing_alpha: 0.9)

    @store.record(measurements_at(utilization: 0.95))
    controller.step(@store)

    # Tick at 60s — well past the minimum interval
    @time = 60.0
    @store.record(measurements_at(utilization: 0.95))
    controller.step(@store)

    refute controller.last_state[:skipped_tick], "Tick should not be skipped after sufficient interval"
  end

  test "D term is clamped when it would exceed MAX_D_TERM" do
    controller = build_controller(smoothing_alpha: 0.9)

    # Establish baseline at low utilization
    @store.record(measurements_at(utilization: 0.1))
    controller.step(@store)

    # Sudden jump to very high utilization — should produce large derivative
    @time = 60.0
    @store.record(measurements_at(utilization: 1.0))
    controller.step(@store)

    state = controller.last_state
    assert state[:d].abs <= Skaler::Controller::MAX_D_TERM,
      "D term #{state[:d]} should be clamped to ±#{Skaler::Controller::MAX_D_TERM}"
  end

  test "nominal_dt adapts to observed tick interval" do
    controller = build_controller(smoothing_alpha: 0.9)

    # Run 5 ticks at 45s intervals
    5.times do |i|
      @time = i * 45.0
      @store.record(measurements_at(utilization: 0.9))
      controller.step(@store)
    end

    state = controller.last_state
    # With consistent 45s ticks, median dt should be 45.0
    assert_in_delta 45.0, state[:nominal_dt], 0.1,
      "nominal_dt should adapt to observed 45s tick interval"
  end

  test "nominal_dt falls back to default with no history" do
    controller = build_controller(smoothing_alpha: 0.9)

    @store.record(measurements_at(utilization: 0.9))
    controller.step(@store)

    state = controller.last_state
    # First tick has no prior history — should use default
    assert_in_delta Skaler::PidController::DEFAULT_NOMINAL_DT, state[:nominal_dt], 0.1
  end

  test "action is held when min_action_interval has not elapsed" do
    controller = build_controller(smoothing_alpha: 0.9, min_action_interval: 300.0)

    # First tick at t=0 — high utilization triggers scale-up
    @store.record(measurements_at(utilization: 0.95))
    delta1 = controller.step(@store)
    assert delta1 > 0, "First action should scale up"
    refute controller.last_state[:held]

    # Second tick at t=60 — still high utilization but too soon to act again
    @time = 60.0
    @store.record(measurements_at(utilization: 0.95))
    delta2 = controller.step(@store)
    assert_equal 0, delta2, "Action should be held"
    assert controller.last_state[:held], "Expected held=true"
  end

  test "action proceeds after min_action_interval elapses" do
    controller = build_controller(smoothing_alpha: 0.9, min_action_interval: 300.0)

    # First action at t=0
    @store.record(measurements_at(utilization: 0.95))
    controller.step(@store)

    # Tick at t=300 — interval has elapsed, should act
    @time = 300.0
    @store.record(measurements_at(utilization: 0.95))
    delta = controller.step(@store)
    assert delta > 0, "Action should proceed after min_action_interval"
    refute controller.last_state[:held]
  end

  test "integral accumulates during held ticks and produces larger action" do
    # Controller WITH action interval hold
    held_controller = build_controller(smoothing_alpha: 0.9, min_action_interval: 300.0)

    # First action at t=0 to establish last_action_at
    @store.record(measurements_at(utilization: 0.95))
    held_controller.step(@store)

    # Observe for 4 ticks during the hold — PID keeps computing
    4.times do |i|
      @time = (i + 1) * 60.0
      @store.record(measurements_at(utilization: 0.95))
      held_controller.step(@store)
    end

    # Act at t=300
    @time = 300.0
    @store.record(measurements_at(utilization: 0.95))
    held_delta = held_controller.step(@store)

    # The held controller's integral should have accumulated over the
    # observation-only ticks, so the I term should be non-zero
    assert held_controller.last_state[:i] > 0,
      "Integral should accumulate during held ticks"
    assert held_delta > 0, "Should act after interval with accumulated integral"
  end

  test "asymmetric hold: scale-down is not held when min_action_interval_down is zero" do
    controller = build_controller(
      smoothing_alpha: 0.9,
      min_action_interval_up: 300.0,
      min_action_interval_down: 0.0
    )

    # First tick at t=0 — high utilization triggers scale-up
    @store.record(measurements_at(utilization: 0.95))
    delta1 = controller.step(@store)
    assert delta1 > 0, "First action should scale up"

    # Second tick at t=60 — utilization drops, should scale down immediately (no hold)
    @time = 60.0
    @store.record(measurements_at(utilization: 0.1))
    delta2 = controller.step(@store)
    assert delta2 < 0, "Scale-down should not be held when min_action_interval_down=0"
    refute controller.last_state[:held]
  end

  test "asymmetric hold: scale-up is still held even when scale-down is unheld" do
    controller = build_controller(
      smoothing_alpha: 0.9,
      min_action_interval_up: 300.0,
      min_action_interval_down: 0.0
    )

    # First tick at t=0 — high utilization triggers scale-up
    @store.record(measurements_at(utilization: 0.95))
    controller.step(@store)

    # Second tick at t=60 — still high but too soon for another scale-up
    @time = 60.0
    @store.record(measurements_at(utilization: 0.95))
    delta2 = controller.step(@store)
    assert_equal 0, delta2, "Scale-up should still be held"
    assert controller.last_state[:held]
  end

  test "skips tick when capacity and busy threads are both zero" do
    controller = build_controller(smoothing_alpha: 0.9)

    # First valid tick to establish some EMA state
    @store.record(measurements_at(utilization: 0.9))
    controller.step(@store)
    saved_before = @store.load_controller_state
    smoothed_before = saved_before[:smoothed_utilization]

    # Zero-capacity tick — should be skipped entirely
    @time = 60.0
    @store.record({active_workers: 0, busy_threads: 0, capacity: 0, ready_queue_depth: 0, completed_since_last: 0})
    delta = controller.step(@store)

    assert_equal 0, delta
    assert controller.last_state[:zero_capacity]

    # PID state should NOT have been updated — smoothed_utilization unchanged
    saved_after = @store.load_controller_state
    assert_equal smoothed_before, saved_after[:smoothed_utilization],
      "Smoothed utilization should not change on zero-capacity tick"
  end

  test "does not skip tick when capacity is zero but busy threads are positive" do
    controller = build_controller(smoothing_alpha: 0.9)

    # Capacity=0 but busy=30 means workers exist — should NOT skip
    @store.record({active_workers: 0, busy_threads: 30, capacity: 0, ready_queue_depth: 0, completed_since_last: 10})
    controller.step(@store)

    refute controller.last_state[:zero_capacity],
      "Should not skip when busy threads prove workers exist"
    assert controller.last_state.key?(:raw_utilization)
  end

  test "claimed jobs used as capacity floor prevents utilization > 1.0 from busy/capacity ratio" do
    controller = build_controller(smoothing_alpha: 1.0, metric_mode: "utilization")

    # Simulate mid-boot: sensor reports capacity=15 but 40 threads are actually busy
    @store.record({active_workers: 3, busy_threads: 40, capacity: 15, ready_queue_depth: 0, completed_since_last: 10})
    controller.step(@store)

    raw = controller.last_state[:raw_utilization]
    assert_equal 1.0, raw,
      "With capacity floor from claimed jobs, utilization should be 40/40=1.0, got #{raw}"
  end

  test "capacity floor does not affect normal operation when reported capacity exceeds busy" do
    controller = build_controller(smoothing_alpha: 1.0, metric_mode: "utilization")

    # Normal: capacity=50, busy=25 — floor doesn't kick in
    @store.record({active_workers: 10, busy_threads: 25, capacity: 50, ready_queue_depth: 0, completed_since_last: 10})
    controller.step(@store)

    raw = controller.last_state[:raw_utilization]
    assert_in_delta 0.5, raw, 0.001,
      "Normal utilization should be 25/50=0.5, got #{raw}"
  end

  test "pressure mode still adds queue factor on top of capped utilization" do
    controller = build_controller(smoothing_alpha: 1.0, metric_mode: "pressure")

    # Mid-boot scenario with queue backlog
    @store.record({active_workers: 3, busy_threads: 40, capacity: 15, ready_queue_depth: 50, completed_since_last: 10})
    controller.step(@store)

    raw = controller.last_state[:raw_utilization]
    # Base util = 40/40 = 1.0, queue_factor = min(50/10, 3.0) = 3.0, total = 4.0 (capped)
    assert raw > 1.0,
      "Pressure mode should add queue factor above the capped 1.0 base, got #{raw}"
  end

  test "PID output is clamped when it would exceed MAX_PID_OUTPUT" do
    controller = build_controller(smoothing_alpha: 0.9)

    # Build up large error over several ticks to produce big P + I + D
    10.times do |i|
      @time = i * 60.0
      @store.record(measurements_at(utilization: 1.0))
      controller.step(@store)
    end

    state = controller.last_state
    assert state[:output].abs <= Skaler::Controller::MAX_PID_OUTPUT,
      "PID output #{state[:output]} should be clamped to ±#{Skaler::Controller::MAX_PID_OUTPUT}"
  end

  private

  def build_controller(warm_up_duration: 0.0, metric_mode: "utilization", pg_cap: 2000, smoothing_alpha: 0.15, min_action_interval: 0.0, min_action_interval_up: nil, min_action_interval_down: nil)
    pid = Skaler::PidController.new(kp: 0.8, ki: 0.1, kd: 0.35, deadband: 0.1)

    constraints = [
      Skaler::PooledResourceConstraint.new(cap: pg_cap, pool_per_worker: 7, name: :pg),
      Skaler::PooledResourceConstraint.new(cap: 5000, pool_per_worker: 10, name: :redis),
      Skaler::MaxInstancesConstraint.new(max: 60)
    ]

    Skaler::Controller.new(
      pid: pid,
      constraints: constraints,
      setpoint: 0.7,
      smoothing_alpha: smoothing_alpha,
      metric_mode: metric_mode,
      warm_up_duration: warm_up_duration,
      min_action_interval: min_action_interval,
      min_action_interval_up: min_action_interval_up,
      min_action_interval_down: min_action_interval_down
    )
  end

  def measurements_at(utilization: 0.5, ready_queue_depth: 0, completed_since_last: 10)
    busy = (utilization * 50).to_i # 10 workers * 5 threads = 50 capacity
    {
      active_workers: 10,
      busy_threads: busy,
      capacity: 50,
      ready_queue_depth: ready_queue_depth,
      completed_since_last: completed_since_last
    }
  end
end
