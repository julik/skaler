# Lightweight \r-based progress bar for simulation runs.
#
# Writes progress updates to an IO (defaults to $stderr) using carriage-return
# overwriting. No gem dependencies.
#
# @example
#   reporter = Skaler::ProgressReporter.new(max_time: 7200, output: $stderr)
#   reporter.tick(current_time)  # called each autoscaler tick
#   reporter.finish              # prints summary line
class Skaler::ProgressReporter
  BAR_WIDTH = 40

  # @param max_time [Numeric] total simulated seconds
  # @param output [IO] where to write progress (default $stderr)
  def initialize(max_time:, output: $stderr)
    @max_time = max_time.to_f
    @output = output
    @wall_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @last_print = 0.0
  end

  # Update progress display.
  #
  # @param current_time [Numeric] current virtual time in seconds
  def tick(current_time)
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    # Throttle to avoid excessive IO — at most every 0.1s wall time
    return if (now - @last_print) < 0.1 && current_time < @max_time

    @last_print = now
    fraction = (@max_time > 0) ? (current_time / @max_time).clamp(0.0, 1.0) : 1.0
    pct = (fraction * 100).round(1)
    filled = (fraction * BAR_WIDTH).round
    bar = "#" * filled + "-" * (BAR_WIDTH - filled)
    elapsed = now - @wall_start
    vtime = format_time(current_time)
    wtime = format_time(elapsed)

    speed = format_speed(current_time, elapsed)
    @output.print "\r[#{bar}] #{pct}%  sim:#{vtime}  wall:#{wtime}, #{speed}  "
  end

  # Print final summary line.
  def finish
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @wall_start
    @output.puts "\rDone. Wall time: #{format_time(elapsed)}#{" " * 40}"
  end

  private

  def format_speed(sim_seconds, wall_seconds)
    return "0x realtime" if wall_seconds <= 0
    ratio = sim_seconds / wall_seconds
    if ratio >= 1.0
      "#{ratio.round}x realtime"
    else
      "%.2fx realtime" % ratio
    end
  end

  def format_time(seconds)
    parts = []
    d, seconds = seconds.divmod(86400)
    h, seconds = seconds.divmod(3600)
    m, s = seconds.divmod(60)
    parts << "#{d.to_i}d" if d >= 1
    parts << "#{h.to_i}h" if h >= 1 || d >= 1
    parts << "#{m.to_i}m" if m >= 1 || h >= 1 || d >= 1
    parts << "#{s.round(1)}s"
    parts.join
  end
end
