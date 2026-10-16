require "test_helper"

class Skaler::ProgressReporterTest < Skaler::TestCase
  class TTYOutput < StringIO
    def initialize(columns: 120)
      super()
      @columns = columns
    end

    def tty? = true

    def winsize = [24, @columns]
  end

  test "tick writes progress to output" do
    output = TTYOutput.new
    reporter = Skaler::ProgressReporter.new(max_time: 100, output: output)

    reporter.tick(50)

    line = output.string
    assert_includes line, "50.0%"
    assert_includes line, "#"
  end

  test "tick at zero shows 0%" do
    output = TTYOutput.new
    reporter = Skaler::ProgressReporter.new(max_time: 100, output: output)

    reporter.tick(0)

    assert_includes output.string, "0.0%"
  end

  test "tick at max_time shows 100%" do
    output = TTYOutput.new
    reporter = Skaler::ProgressReporter.new(max_time: 100, output: output)

    reporter.tick(100)

    assert_includes output.string, "100.0%"
  end

  test "tick clamps beyond max_time" do
    output = TTYOutput.new
    reporter = Skaler::ProgressReporter.new(max_time: 100, output: output)

    reporter.tick(200)

    assert_includes output.string, "100.0%"
  end

  test "finish writes done message" do
    output = TTYOutput.new
    reporter = Skaler::ProgressReporter.new(max_time: 100, output: output)

    reporter.finish

    assert_includes output.string, "Done."
  end

  test "handles zero max_time" do
    output = TTYOutput.new
    reporter = Skaler::ProgressReporter.new(max_time: 0, output: output)

    reporter.tick(0)

    assert_includes output.string, "100.0%"
  end

  test "each redraw on a TTY erases the line first" do
    output = TTYOutput.new
    reporter = Skaler::ProgressReporter.new(max_time: 100, output: output)

    reporter.tick(50)
    reporter.finish

    assert output.string.start_with?("\r\e[2K[")
    assert_includes output.string, "\r\e[2KDone."
  end

  test "writes only the summary when the output is not a TTY" do
    output = StringIO.new
    reporter = Skaler::ProgressReporter.new(max_time: 100, output: output)

    reporter.tick(50)
    reporter.tick(100)
    reporter.finish

    assert_match(/\ADone\. Wall time: [\d.]+s\n\z/, output.string) # no bar, no control characters
  end

  test "every redraw fits within the terminal width" do
    [40, 80, 200].each do |columns|
      output = TTYOutput.new(columns: columns)
      reporter = Skaler::ProgressReporter.new(max_time: 86_400 * 3, output: output)

      reporter.tick(86_400 * 2 + 3_599.9) # longest time strings

      drawn = output.string.delete_prefix("\r\e[2K")
      assert_operator drawn.length, :<, columns, "a #{drawn.length}-char line wraps at #{columns} columns"
      assert drawn.start_with?("["), "the bar should survive at #{columns} columns"
    end
  end
end
