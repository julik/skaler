# Pure PID (Proportional-Integral-Derivative) controller for autoscaling.
#
# Computes a control output from the current error and a history of past signals.
# Contains no I/O — all state is passed in and results passed out.
#
# This is a discrete-time PID: the integral and derivative are weighted by
# the actual elapsed time (dt) between samples, so irregular tick intervals
# (common when jobs run on busy workers) don't distort the I and D terms.
#
# @example Basic usage
#   pid = Skaler::PidController.new(kp: 0.5, ki: 0.1, kd: 0.2, deadband: 0.05)
#   result = pid.compute(error: 0.2, signal_history: [[0.15, t-60], [0.18, t-30]], now: t)
#   result[:output]  # => combined PID output
#   result[:deadband] # => true if |output| < deadband threshold
#
# @example With no history (first tick)
#   result = pid.compute(error: 0.3, signal_history: [], now: t)
#   result[:d] # => 0.0 (no previous error for derivative)
class Skaler::PidController
  # Default nominal tick interval in seconds. Used to normalize dt so that
  # gains behave identically whether samples arrive at exactly 60s or not.
  # Callers can override this per-compute via the nominal_dt: parameter.
  DEFAULT_NOMINAL_DT = 60.0

  # @param kp [Float] Proportional gain
  # @param ki [Float] Integral gain
  # @param kd [Float] Derivative gain
  # @param deadband [Float] Output threshold below which no action is taken
  def initialize(kp:, ki:, kd:, deadband:)
    @kp = kp
    @ki = ki
    @kd = kd
    @deadband = deadband
  end

  # Compute the PID output for the current error given signal history.
  #
  # @param error [Float] Current error (process_variable - setpoint)
  # @param signal_history [Array<Array(Float, Numeric)>] Past [error_value, timestamp] pairs
  # @param now [Numeric] Current timestamp (seconds), used to compute dt for the derivative
  # @param nominal_dt [Float] Tick interval used to normalize dt. Defaults to DEFAULT_NOMINAL_DT.
  #   Pass the observed median tick interval to auto-adapt gains to the actual sampling rate.
  # @return [Hash] PID computation result with keys:
  #   :p, :i, :d — individual term contributions
  #   :output — combined PID output
  #   :error — the input error value
  #   :deadband — true if |output| < deadband (caller should skip action)
  #   :clamped — always false; caller sets this when constraints prevent action
  def compute(error:, signal_history:, now:, nominal_dt: DEFAULT_NOMINAL_DT)
    # Discrete integral: sum(error_i * dt_i / nominal_dt) so that a sample
    # spanning 120s counts twice as much as one spanning 60s.
    integral = 0.0
    signal_history.each_cons(2) do |(_, t_prev), (err_val, t_curr)|
      dt = (t_curr - t_prev).clamp(1.0, nominal_dt * 5)
      integral += err_val * (dt / nominal_dt)
    end
    # First entry has no predecessor — count it as one nominal interval
    if signal_history.size == 1
      integral += signal_history[0][0]
    end

    # Discrete derivative: (error - prev_error) / (dt / nominal_dt)
    if signal_history.any?
      previous_error = signal_history.last[0]
      previous_ts = signal_history.last[1]
      dt = (now - previous_ts).clamp(1.0, nominal_dt * 5)
      derivative = (error - previous_error) / (dt / nominal_dt)
    else
      derivative = 0.0
    end

    p_term = @kp * error
    i_term = @ki * integral
    d_term = @kd * derivative
    output = p_term + i_term + d_term

    {
      p: p_term,
      i: i_term,
      d: d_term,
      output: output,
      error: error,
      deadband: output.abs < @deadband,
      clamped: false
    }
  end
end
