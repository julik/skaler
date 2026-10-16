require "test_helper"

class Skaler::PidControllerTest < Skaler::TestCase
  setup do
    @pid = Skaler::PidController.new(kp: 0.5, ki: 0.1, kd: 0.2, deadband: 0.05)
  end

  test "computes proportional term from error" do
    result = @pid.compute(error: 0.2, signal_history: [], now: 60)
    assert_in_delta 0.1, result[:p], 0.001 # 0.5 * 0.2
  end

  test "computes integral weighted by dt" do
    # Three samples at 60s intervals — each dt/nominal_dt = 1.0
    history = [[0.1, 60], [0.2, 120], [0.15, 180]]
    result = @pid.compute(error: 0.2, signal_history: history, now: 240)
    # integral via each_cons(2):
    #   [60→120]: 0.2 * (60/60) = 0.2
    #   [120→180]: 0.15 * (60/60) = 0.15
    # total = 0.35, i_term = 0.1 * 0.35 = 0.035
    assert_in_delta 0.035, result[:i], 0.001
  end

  test "integral weights longer intervals more heavily" do
    # Two samples: second one spans 120s instead of 60s
    short = [[0.2, 60], [0.2, 120]]
    long = [[0.2, 60], [0.2, 180]]

    result_short = @pid.compute(error: 0.2, signal_history: short, now: 180)
    result_long = @pid.compute(error: 0.2, signal_history: long, now: 240)
    assert result_long[:i] > result_short[:i],
      "Longer interval should produce larger integral contribution"
  end

  test "computes derivative normalized by dt" do
    # Error dropped from 0.3 to 0.2 over 60s (1 nominal interval)
    history = [[0.3, 60]]
    result = @pid.compute(error: 0.2, signal_history: history, now: 120)
    # derivative = (0.2 - 0.3) / (60/60) = -0.1, d_term = 0.2 * -0.1 = -0.02
    assert_in_delta(-0.02, result[:d], 0.001)
  end

  test "derivative scales with interval length" do
    # Same error change over 120s — rate of change is half
    history = [[0.3, 60]]
    result = @pid.compute(error: 0.2, signal_history: history, now: 180)
    # derivative = (0.2 - 0.3) / (120/60) = -0.05, d_term = 0.2 * -0.05 = -0.01
    assert_in_delta(-0.01, result[:d], 0.001)
  end

  test "derivative is zero with empty history" do
    result = @pid.compute(error: 0.2, signal_history: [], now: 60)
    assert_in_delta 0.0, result[:d], 0.001
  end

  test "output is sum of P + I + D terms" do
    result = @pid.compute(error: 0.2, signal_history: [], now: 60)
    expected = result[:p] + result[:i] + result[:d]
    assert_in_delta expected, result[:output], 0.001
  end

  test "deadband is true when output magnitude is below threshold" do
    result = @pid.compute(error: 0.01, signal_history: [], now: 60)
    assert result[:deadband], "expected deadband to be true for tiny error"
  end

  test "deadband is false when output exceeds threshold" do
    result = @pid.compute(error: 0.5, signal_history: [], now: 60)
    refute result[:deadband], "expected deadband to be false for large error"
  end

  test "clamped is always false (caller sets it)" do
    result = @pid.compute(error: 0.5, signal_history: [], now: 60)
    refute result[:clamped]
  end

  test "negative error produces negative output" do
    result = @pid.compute(error: -0.3, signal_history: [], now: 60)
    assert result[:output] < 0, "expected negative output for negative error"
  end

  test "accumulated positive history amplifies positive output" do
    no_history = @pid.compute(error: 0.2, signal_history: [], now: 600)
    history = (1..10).map { |i| [0.2, i * 60] }
    with_history = @pid.compute(error: 0.2, signal_history: history, now: 660)
    assert with_history[:output] > no_history[:output],
      "integral should amplify output with accumulated positive errors"
  end

  test "negative derivative dampens positive output" do
    history = [[0.3, 60]]
    result = @pid.compute(error: 0.1, signal_history: history, now: 120)
    assert result[:d] < 0, "derivative should be negative when error is decreasing"
  end

  test "nominal_dt parameter overrides default normalization" do
    history = [[0.3, 60]]
    # With default nominal_dt (60s): derivative = (0.2 - 0.3) / (60/60) = -0.1
    result_default = @pid.compute(error: 0.2, signal_history: history, now: 120)
    # With nominal_dt = 30s: derivative = (0.2 - 0.3) / (60/30) = -0.05
    result_custom = @pid.compute(error: 0.2, signal_history: history, now: 120, nominal_dt: 30.0)

    assert_in_delta(-0.02, result_default[:d], 0.001) # kd=0.2 * -0.1
    assert_in_delta(-0.01, result_custom[:d], 0.001)  # kd=0.2 * -0.05
  end

  test "dt is clamped to prevent extreme values" do
    # Very short dt (1s) — should clamp to 1s minimum
    history = [[0.3, 59.5]]
    result = @pid.compute(error: 0.1, signal_history: history, now: 60)
    # dt clamped to 1.0, dt/nominal = 1/60 ≈ 0.0167
    # derivative = (0.1 - 0.3) / 0.0167 ≈ -12.0, d_term = 0.2 * -12.0 = -2.4
    assert result[:d] < 0, "derivative should still be negative"
    # Without clamping this would be infinite; with clamping it's large but finite
    assert result[:d].finite?, "derivative should be finite"
  end
end
