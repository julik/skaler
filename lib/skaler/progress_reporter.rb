# Lightweight progress bar for simulation runs.
#
# On a TTY the bar is redrawn in place, erasing the line each time. When the
# output is not a terminal (a pipe, a log file) only the final summary line is
# written, since in-place redraws would just pile up there. No gem dependencies.
#
# @example
#   reporter = Skaler::ProgressReporter.new(max_time: 7200, output: $stderr)
#   reporter.tick(current_time)  # called each autoscaler tick
#   reporter.finish              # prints summary line
class Skaler::ProgressReporter
  BAR_WIDTH = 40
  MIN_BAR_WIDTH = 10
  DEFAULT_COLUMNS = 80
  ERASE_LINE = "\r\e[2K"

  # @param max_time [Numeric] total simulated seconds
  # @param output [IO] where to write progress (default $stderr)
  def initialize(max_time:, output: $stderr)
    @max_time = max_time.to_f
    @output = output
    @wall_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @last_print = 0.0
    @tty = output.respond_to?(:tty?) && output.tty?
  end

  # Update progress display.
  #
  # @param current_time [Numeric] current virtual time in seconds
  def tick(current_time)
    return unless @tty

    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    # Throttle to avoid excessive IO — at most every 0.1s wall time
    return if (now - @last_print) < 0.1 && current_time < @max_time

    @last_print = now
    fraction = (@max_time > 0) ? (current_time / @max_time).clamp(0.0, 1.0) : 1.0
    pct = (fraction * 100).round(1)
    elapsed = now - @wall_start
    status = " #{pct}%  sim:#{format_time(current_time)}  wall:#{format_time(elapsed)}, #{format_speed(current_time, elapsed)}"

    # A line that wraps can't be redrawn - `\r` and erase-line only reach its last row.
    # Shrink the bar to make room, then cut the line one short of the last column
    # (writing into it makes some terminals wrap early)
    columns = terminal_columns
    bar_width = (columns - status.length - 3).clamp(MIN_BAR_WIDTH, BAR_WIDTH)
    filled = (fraction * bar_width).round
    line = "[#{"#" * filled}#{"-" * (bar_width - filled)}]#{status}"
    @output.print ERASE_LINE + line[0, columns - 1]
  end

  # Print final summary line.
  def finish
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @wall_start
    @output.print ERASE_LINE if @tty
    @output.puts "Done. Wall time: #{format_time(elapsed)}"
  end

  private

  def terminal_columns
    require "io/console"
    columns = @output.winsize[1] if @output.respond_to?(:winsize)
    (columns.to_i > 0) ? columns : DEFAULT_COLUMNS
  rescue SystemCallError
    DEFAULT_COLUMNS
  end

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
