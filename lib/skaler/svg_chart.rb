# Pure Ruby SVG chart renderer for Skaler simulation traces.
#
# Produces a 5-panel stacked chart:
# 1. Instances — step line with scale command markers
# 2. Utilization — raw + smoothed + setpoint line
# 3. Arrivals per Tick — filled area chart of inflow demand
# 4. Ready Queue Depth — filled area chart of backlog
# 5. PID Output — p/i/d term lines + zero line
#
# Zero external dependencies.
#
# @example
#   svg_string = Skaler::SvgChart.render(trace, setpoint: 0.7)
#   File.write("trace.svg", svg_string)
class Skaler::SvgChart
  TOTAL_WIDTH = 1800
  PANEL_HEIGHT = 160
  PANEL_GAP = 30
  MARGIN = {top: 30, right: 30, bottom: 40, left: 70}
  PANELS = 6
  TOTAL_HEIGHT = MARGIN[:top] + PANELS * PANEL_HEIGHT + (PANELS - 1) * PANEL_GAP + MARGIN[:bottom]
  PLOT_WIDTH = TOTAL_WIDTH - MARGIN[:left] - MARGIN[:right]

  COLORS = {
    instances: "#2563eb",
    raw_utilization: "#f97316",
    utilization: "#1d4ed8",
    setpoint: "#dc2626",
    queue: "#16a34a",
    queue_fill: "#bbf7d0",
    arrivals: "#d946ef",
    arrivals_fill: "#f0abfc",
    p: "#ef4444",
    i: "#3b82f6",
    d: "#a855f7",
    zero: "#9ca3af",
    latency_p50: "#0ea5e9",
    latency_p95: "#f59e0b",
    latency_max: "#ef4444",
    scale_up: "#22c55e",
    scale_down: "#ef4444",
    grid: "#e5e7eb",
    axis: "#374151",
    text: "#374151",
    bg: "#ffffff"
  }.freeze

  # Render a trace array into an SVG string.
  #
  # @param trace [Array<Hash>] snapshot array from Simulator#run
  # @param setpoint [Float] target utilization for reference line
  # @return [String] SVG document
  def self.render(trace, setpoint: 0.7)
    new(trace, setpoint).render
  end

  def initialize(trace, setpoint)
    @trace = trace
    @setpoint = setpoint
  end

  def render
    return empty_svg if @trace.empty?

    lines = []
    lines << svg_open
    lines << defs
    lines << background
    lines << panel_instances(0)
    lines << panel_utilization(1)
    lines << panel_arrivals(2)
    lines << panel_queue(3)
    lines << panel_pid(4)
    lines << panel_latency(5)
    lines << svg_close
    lines.join("\n")
  end

  private

  def empty_svg
    %(<svg xmlns="http://www.w3.org/2000/svg" width="#{TOTAL_WIDTH}" height="100">) +
      %(<text x="#{TOTAL_WIDTH / 2}" y="50" text-anchor="middle" font-family="system-ui, sans-serif" ) +
      %(font-size="14" fill="#{COLORS[:text]}">No trace data</text></svg>)
  end

  def svg_open
    %(<svg xmlns="http://www.w3.org/2000/svg" width="#{TOTAL_WIDTH}" height="#{TOTAL_HEIGHT}" ) +
      %(font-family="system-ui, -apple-system, sans-serif" font-size="11">)
  end

  def svg_close
    "</svg>"
  end

  def defs
    "<defs>" \
      "<style>text { fill: " + COLORS[:text] + "; } " \
      ".grid { stroke: " + COLORS[:grid] + "; stroke-width: 0.5; } " \
      ".axis { stroke: " + COLORS[:axis] + "; stroke-width: 1; }" \
      "</style>" \
      "</defs>"
  end

  def background
    %(<rect width="#{TOTAL_WIDTH}" height="#{TOTAL_HEIGHT}" fill="#{COLORS[:bg]}"/>)
  end

  # --- Time axis helpers ---

  def times
    @times ||= @trace.map { |s| s[:t] }
  end

  def t_min
    @t_min ||= times.first
  end

  def t_max
    @t_max ||= [times.last, t_min + 1].max
  end

  def x_for(t)
    MARGIN[:left] + ((t - t_min) / (t_max - t_min)) * PLOT_WIDTH
  end

  def panel_y_offset(panel_index)
    MARGIN[:top] + panel_index * (PANEL_HEIGHT + PANEL_GAP)
  end

  # Map a value to y within a panel (top = max, bottom = min)
  def y_for(value, min_val, max_val, panel_index)
    range = max_val - min_val
    range = 1.0 if range == 0
    fraction = (value - min_val).to_f / range
    top = panel_y_offset(panel_index)
    top + PANEL_HEIGHT - (fraction * PANEL_HEIGHT)
  end

  # --- Panel 1: Instances ---

  def panel_instances(idx)
    values = @trace.map { |s| (s[:instances] || 0).to_i }
    min_v = 0
    max_v = [values.max || 1, 1].max
    max_v = (max_v * 1.1).ceil

    parts = []
    parts << panel_frame("Instances", idx, min_v, max_v, format: "%d", integer_ticks: true)
    parts << step_line(values, min_v, max_v, idx, COLORS[:instances], 2)
    parts << scale_markers(min_v, max_v, idx)
    parts << legend(idx, [["instances", COLORS[:instances]]])
    parts.join("\n")
  end

  # --- Panel 2: Utilization ---

  def panel_utilization(idx)
    raw = @trace.map { |s| s[:raw_utilization] || 0 }
    smoothed = @trace.map { |s| s[:utilization] || 0 }
    all = raw + smoothed + [@setpoint]
    min_v = 0
    max_v = [all.max || 1, 1].max
    max_v = [(max_v * 1.1), max_v + 0.1].min.round(2)

    parts = []
    parts << panel_frame("Utilization", idx, min_v, max_v, format: "%.2f")
    parts << polyline(raw, min_v, max_v, idx, COLORS[:raw_utilization], 1)
    parts << polyline(smoothed, min_v, max_v, idx, COLORS[:utilization], 2)

    # Setpoint dashed line
    sy = y_for(@setpoint, min_v, max_v, idx)
    parts << %(<line x1="#{MARGIN[:left]}" y1="#{sy}" x2="#{MARGIN[:left] + PLOT_WIDTH}" y2="#{sy}" ) +
      %(stroke="#{COLORS[:setpoint]}" stroke-width="1" stroke-dasharray="6,3"/>)

    parts << legend(idx, [
      ["raw", COLORS[:raw_utilization]],
      ["smoothed", COLORS[:utilization]],
      ["setpoint", COLORS[:setpoint]]
    ])
    parts.join("\n")
  end

  # --- Panel 3: Arrivals ---

  def panel_arrivals(idx)
    values = @trace.map { |s| s[:arrivals_since_last] || 0 }
    min_v = 0
    max_v = [values.max || 1, 1].max
    max_v = (max_v * 1.1).ceil

    parts = []
    parts << panel_frame("Arrivals per Tick", idx, min_v, max_v, integer_ticks: true)
    parts << area(values, min_v, max_v, idx, COLORS[:arrivals], COLORS[:arrivals_fill])
    parts << legend(idx, [["arrivals", COLORS[:arrivals]]])
    parts.join("\n")
  end

  # --- Panel 4: Queue Backlog ---

  def panel_queue(idx)
    values = @trace.map { |s| s[:ready_queue_depth] || 0 }
    min_v = 0
    max_v = [values.max || 1, 1].max
    max_v = (max_v * 1.1).ceil

    parts = []
    parts << panel_frame("Ready Queue Depth", idx, min_v, max_v)
    parts << area(values, min_v, max_v, idx, COLORS[:queue], COLORS[:queue_fill])
    parts << legend(idx, [["depth", COLORS[:queue]]])
    parts.join("\n")
  end

  # --- Panel 5: PID Output ---

  def panel_pid(idx)
    p_vals = @trace.map { |s| s[:p] || 0 }
    i_vals = @trace.map { |s| s[:i] || 0 }
    d_vals = @trace.map { |s| s[:d] || 0 }
    all = p_vals + i_vals + d_vals
    min_v = all.min || 0
    max_v = all.max || 1
    padding = [(max_v - min_v) * 0.1, 0.1].max
    min_v -= padding
    max_v += padding

    parts = []
    parts << panel_frame("PID Output", idx, min_v, max_v, format: "%.2f")

    # Zero line
    zy = y_for(0, min_v, max_v, idx)
    parts << %(<line x1="#{MARGIN[:left]}" y1="#{zy}" x2="#{MARGIN[:left] + PLOT_WIDTH}" y2="#{zy}" ) +
      %(stroke="#{COLORS[:zero]}" stroke-width="1" stroke-dasharray="4,4"/>)

    parts << polyline(p_vals, min_v, max_v, idx, COLORS[:p], 1.5)
    parts << polyline(i_vals, min_v, max_v, idx, COLORS[:i], 1.5)
    parts << polyline(d_vals, min_v, max_v, idx, COLORS[:d], 1.5)
    parts << legend(idx, [["P", COLORS[:p]], ["I", COLORS[:i]], ["D", COLORS[:d]]])
    parts.join("\n")
  end

  # --- Panel 6: Queue Latency (log scale) ---

  LOG_LATENCY_FLOOR = 0.001 # 1ms floor for log scale

  def panel_latency(idx)
    p50 = @trace.map { |s| s[:latency_p50] || 0 }
    p95 = @trace.map { |s| s[:latency_p95] || 0 }
    max_vals = @trace.map { |s| s[:latency_max] || 0 }

    peak = [p50.max || 0, p95.max || 0, max_vals.max || 0].max
    log_max = if peak > 0
      10**Math.log10(peak).ceil
    else
      1.0
    end
    log_min = LOG_LATENCY_FLOOR

    parts = []
    parts << panel_frame_log("Queue Latency", idx, log_min, log_max)
    parts << polyline_log(max_vals, log_min, log_max, idx, COLORS[:latency_max], 1, 0.6)
    parts << polyline_log(p95, log_min, log_max, idx, COLORS[:latency_p95], 1.5)
    parts << polyline_log(p50, log_min, log_max, idx, COLORS[:latency_p50], 2)
    parts << legend(idx, [
      ["p50", COLORS[:latency_p50]],
      ["p95", COLORS[:latency_p95]],
      ["max", COLORS[:latency_max]]
    ])
    parts.join("\n")
  end

  def y_for_log(value, log_min, log_max, panel_index)
    clamped = [value, log_min].max
    frac = (Math.log10(clamped) - Math.log10(log_min)) / (Math.log10(log_max) - Math.log10(log_min))
    top = panel_y_offset(panel_index)
    top + PANEL_HEIGHT - (frac * PANEL_HEIGHT)
  end

  def polyline_log(values, log_min, log_max, panel_idx, color, width, opacity = nil)
    points = values.each_with_index.map do |v, i|
      "#{fmt(x_for(times[i]))},#{fmt(y_for_log(v, log_min, log_max, panel_idx))}"
    end
    opacity_attr = opacity ? %( opacity="#{opacity}") : ""
    %(<polyline points="#{points.join(" ")}" fill="none" stroke="#{color}" stroke-width="#{width}"#{opacity_attr}/>)
  end

  def latency_label(seconds)
    if seconds < 1.0
      "#{(seconds * 1000).round}ms"
    else
      "#{seconds.round(1)}s"
    end
  end

  def panel_frame_log(title, idx, log_min, log_max)
    top = panel_y_offset(idx)
    parts = []

    parts << %(<text x="#{MARGIN[:left]}" y="#{top - 8}" font-weight="bold" font-size="12">#{title}</text>)
    parts << %(<rect x="#{MARGIN[:left]}" y="#{top}" width="#{PLOT_WIDTH}" height="#{PANEL_HEIGHT}" ) +
      %(fill="none" class="axis"/>)

    # Log-spaced ticks: powers of 10 from log_min to log_max
    exp_min = Math.log10(log_min).floor
    exp_max = Math.log10(log_max).ceil
    (exp_min..exp_max).each do |exp|
      val = 10.0**exp
      next if val < log_min || val > log_max
      frac = (exp - Math.log10(log_min)) / (Math.log10(log_max) - Math.log10(log_min))
      y = top + PANEL_HEIGHT - (frac * PANEL_HEIGHT)
      label = latency_label(val)
      parts << %(<line x1="#{MARGIN[:left] - 4}" y1="#{y}" x2="#{MARGIN[:left]}" y2="#{y}" class="axis"/>)
      parts << %(<text x="#{MARGIN[:left] - 8}" y="#{y + 4}" text-anchor="end" font-size="10">#{label}</text>)
      if frac > 0 && frac < 1
        parts << %(<line x1="#{MARGIN[:left]}" y1="#{y}" x2="#{MARGIN[:left] + PLOT_WIDTH}" y2="#{y}" class="grid"/>)
      end
    end

    # X-axis ticks
    tick_count = 6
    tick_count.times do |i|
      frac = i / (tick_count - 1).to_f
      t = t_min + frac * (t_max - t_min)
      x = x_for(t)
      bottom = top + PANEL_HEIGHT
      parts << %(<line x1="#{x}" y1="#{bottom}" x2="#{x}" y2="#{bottom + 4}" class="axis"/>)
      if idx == PANELS - 1
        label = format("%dm", (t / 60).round)
        parts << %(<text x="#{x}" y="#{bottom + 18}" text-anchor="middle" font-size="10">#{label}</text>)
      end
      if i > 0 && i < tick_count - 1
        parts << %(<line x1="#{x}" y1="#{top}" x2="#{x}" y2="#{bottom}" class="grid"/>)
      end
    end

    parts.join("\n")
  end

  # --- Drawing primitives ---

  def panel_frame(title, idx, min_v, max_v, format: "%g", integer_ticks: false)
    top = panel_y_offset(idx)
    parts = []

    # Title
    parts << %(<text x="#{MARGIN[:left]}" y="#{top - 8}" font-weight="bold" font-size="12">#{title}</text>)

    # Border
    parts << %(<rect x="#{MARGIN[:left]}" y="#{top}" width="#{PLOT_WIDTH}" height="#{PANEL_HEIGHT}" ) +
      %(fill="none" class="axis"/>)

    # Y-axis ticks
    tick_values = if integer_ticks
      integer_tick_values(min_v.to_i, max_v.to_i, 5)
    else
      5.times.map { |i| min_v + (i / 4.0) * (max_v - min_v) }
    end

    tick_values.each do |val|
      frac = (max_v == min_v) ? 0.0 : (val - min_v).to_f / (max_v - min_v)
      y = top + PANEL_HEIGHT - (frac * PANEL_HEIGHT)
      label = format(format, val)
      parts << %(<line x1="#{MARGIN[:left] - 4}" y1="#{y}" x2="#{MARGIN[:left]}" y2="#{y}" class="axis"/>)
      parts << %(<text x="#{MARGIN[:left] - 8}" y="#{y + 4}" text-anchor="end" font-size="10">#{label}</text>)
      if frac > 0 && frac < 1
        parts << %(<line x1="#{MARGIN[:left]}" y1="#{y}" x2="#{MARGIN[:left] + PLOT_WIDTH}" y2="#{y}" class="grid"/>)
      end
    end

    # X-axis ticks (time in minutes, ~6 ticks)
    tick_count = 6
    tick_count.times do |i|
      frac = i / (tick_count - 1).to_f
      t = t_min + frac * (t_max - t_min)
      x = x_for(t)
      bottom = top + PANEL_HEIGHT
      parts << %(<line x1="#{x}" y1="#{bottom}" x2="#{x}" y2="#{bottom + 4}" class="axis"/>)
      if idx == PANELS - 1 # Only label x-axis on bottom panel
        label = format("%dm", (t / 60).round)
        parts << %(<text x="#{x}" y="#{bottom + 18}" text-anchor="middle" font-size="10">#{label}</text>)
      end
      if i > 0 && i < tick_count - 1
        parts << %(<line x1="#{x}" y1="#{top}" x2="#{x}" y2="#{bottom}" class="grid"/>)
      end
    end

    parts.join("\n")
  end

  def polyline(values, min_v, max_v, panel_idx, color, width, opacity = nil)
    points = values.each_with_index.map do |v, i|
      "#{fmt(x_for(times[i]))},#{fmt(y_for(v, min_v, max_v, panel_idx))}"
    end
    opacity_attr = opacity ? %( opacity="#{opacity}") : ""
    %(<polyline points="#{points.join(" ")}" fill="none" stroke="#{color}" stroke-width="#{width}"#{opacity_attr}/>)
  end

  def step_line(values, min_v, max_v, panel_idx, color, width)
    points = []
    values.each_with_index do |v, i|
      x = fmt(x_for(times[i]))
      y = fmt(y_for(v, min_v, max_v, panel_idx))
      if i > 0
        # Horizontal segment first (step)
        points << "#{x},#{fmt(y_for(values[i - 1], min_v, max_v, panel_idx))}"
      end
      points << "#{x},#{y}"
    end
    %(<polyline points="#{points.join(" ")}" fill="none" stroke="#{color}" stroke-width="#{width}"/>)
  end

  def area(values, min_v, max_v, panel_idx, stroke_color, fill_color)
    baseline_y = y_for(min_v, min_v, max_v, panel_idx)
    points = []
    # Start at baseline
    points << "#{fmt(x_for(times.first))},#{fmt(baseline_y)}"
    values.each_with_index do |v, i|
      points << "#{fmt(x_for(times[i]))},#{fmt(y_for(v, min_v, max_v, panel_idx))}"
    end
    # Close back to baseline
    points << "#{fmt(x_for(times.last))},#{fmt(baseline_y)}"
    %(<polygon points="#{points.join(" ")}" fill="#{fill_color}" opacity="0.5" stroke="#{stroke_color}" stroke-width="1.5"/>)
  end

  def scale_markers(min_v, max_v, panel_idx)
    parts = []
    @trace.each do |s|
      cmd = s[:scale_command]
      next unless cmd

      x = x_for(s[:t])
      color = cmd.start_with?("+") ? COLORS[:scale_up] : COLORS[:scale_down]
      top = panel_y_offset(panel_idx)
      parts << %(<line x1="#{fmt(x)}" y1="#{top}" x2="#{fmt(x)}" y2="#{top + PANEL_HEIGHT}" ) +
        %(stroke="#{color}" stroke-width="1" stroke-dasharray="3,3" opacity="0.6"/>)
    end
    parts.join("\n")
  end

  def legend(panel_idx, items)
    top = panel_y_offset(panel_idx)
    x_start = MARGIN[:left] + PLOT_WIDTH - items.size * 80
    parts = items.each_with_index.map do |(label, color), i|
      x = x_start + i * 80
      %(<rect x="#{x}" y="#{top + 6}" width="12" height="3" fill="#{color}"/>) +
        %(<text x="#{x + 16}" y="#{top + 12}" font-size="10">#{label}</text>)
    end
    parts.join("\n")
  end

  # Pick up to `max_ticks` evenly spaced integer values spanning [min_v, max_v].
  def integer_tick_values(min_v, max_v, max_ticks)
    range = max_v - min_v
    return [min_v] if range == 0

    # Find a nice step size (1, 2, 5, 10, 20, 50, ...)
    raw_step = range.to_f / (max_ticks - 1)
    magnitude = 10**Math.log10([raw_step, 1].max).floor
    step = [1, 2, 5, 10].map { |s| s * magnitude }.find { |s| s >= raw_step } || magnitude * 10

    first = (min_v.to_f / step).ceil * step
    first = min_v if first > min_v && (first - min_v) < step * 0.5

    values = [min_v]
    v = first
    while v < max_v
      values << v unless v == min_v
      v += step
    end
    values << max_v unless values.last == max_v
    values.uniq
  end

  def fmt(n)
    n.round(1)
  end
end
