require "test_helper"

class Skaler::SvgChartTest < Skaler::TestCase
  test "render produces valid SVG with panel titles" do
    trace = build_trace(20)

    svg = Skaler::SvgChart.render(trace, setpoint: 0.7)

    assert svg.start_with?("<svg")
    assert_includes svg, "</svg>"
    assert_includes svg, "Instances"
    assert_includes svg, "Utilization"
    assert_includes svg, "Ready Queue Depth"
    assert_includes svg, "PID Output"
  end

  test "render includes setpoint line" do
    trace = build_trace(10)

    svg = Skaler::SvgChart.render(trace, setpoint: 0.7)

    assert_includes svg, "stroke-dasharray"
    assert_includes svg, "#dc2626" # setpoint color
  end

  test "render handles empty trace" do
    svg = Skaler::SvgChart.render([], setpoint: 0.7)

    assert_includes svg, "No trace data"
    assert_includes svg, "<svg"
  end

  test "render handles single-point trace" do
    trace = [{
      t: 0.0, instances: 2, utilization: 0.5, raw_utilization: 0.6,
      ready_queue_depth: 0, p: 0.1, i: 0.0, d: 0.0,
      scale_command: nil
    }]

    svg = Skaler::SvgChart.render(trace, setpoint: 0.7)

    assert svg.start_with?("<svg")
    assert_includes svg, "</svg>"
  end

  test "render includes scale markers for scale commands" do
    trace = build_trace(10)
    trace[3][:scale_command] = "+2"
    trace[7][:scale_command] = "-1"

    svg = Skaler::SvgChart.render(trace, setpoint: 0.7)

    # Scale up color (green) and scale down color (red) should appear
    assert_includes svg, "#22c55e"
    assert_includes svg, "#ef4444"
  end

  test "render includes legend entries" do
    trace = build_trace(5)

    svg = Skaler::SvgChart.render(trace, setpoint: 0.7)

    assert_includes svg, "instances"
    assert_includes svg, "smoothed"
    assert_includes svg, "depth"
  end

  private

  def build_trace(count)
    count.times.map do |i|
      t = i * 60.0
      {
        t: t,
        instances: 2 + i / 3,
        utilization: 0.3 + (i * 0.05),
        raw_utilization: 0.35 + (i * 0.04),
        ready_queue_depth: [0, i - 5].max * 10,
        p: 0.1 * (i - count / 2),
        i: 0.02 * i,
        d: -0.05 * (i % 3),
        scale_command: nil
      }
    end
  end
end
