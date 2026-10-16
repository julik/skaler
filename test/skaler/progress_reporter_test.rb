require "test_helper"

class Skaler::ProgressReporterTest < Skaler::TestCase
  test "tick writes progress to output" do
    output = StringIO.new
    reporter = Skaler::ProgressReporter.new(max_time: 100, output: output)

    reporter.tick(50)

    line = output.string
    assert_includes line, "50.0%"
    assert_includes line, "#"
  end

  test "tick at zero shows 0%" do
    output = StringIO.new
    reporter = Skaler::ProgressReporter.new(max_time: 100, output: output)

    reporter.tick(0)

    assert_includes output.string, "0.0%"
  end

  test "tick at max_time shows 100%" do
    output = StringIO.new
    reporter = Skaler::ProgressReporter.new(max_time: 100, output: output)

    reporter.tick(100)

    assert_includes output.string, "100.0%"
  end

  test "tick clamps beyond max_time" do
    output = StringIO.new
    reporter = Skaler::ProgressReporter.new(max_time: 100, output: output)

    reporter.tick(200)

    assert_includes output.string, "100.0%"
  end

  test "finish writes done message" do
    output = StringIO.new
    reporter = Skaler::ProgressReporter.new(max_time: 100, output: output)

    reporter.finish

    assert_includes output.string, "Done."
  end

  test "handles zero max_time" do
    output = StringIO.new
    reporter = Skaler::ProgressReporter.new(max_time: 0, output: output)

    reporter.tick(0)

    assert_includes output.string, "100.0%"
  end
end
