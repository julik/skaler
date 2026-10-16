# Collects per-step snapshots from the autoscaler for analysis.
#
# The autoscaler calls `trace.record(time, metrics_hash)` each time it fires.
# Produces the same kind of trace array the existing Skaler::Simulator returns.
#
# Also acts as a Loop observer via `on_step`, translating control-loop output
# to the existing snapshot format for backward compatibility.
#
# @example Direct recording
#   trace = Skaler::Trace.new
#   trace.record(0.0, { instances: 5, utilization: 0.7, ... })
#   trace.record(60.0, { instances: 7, utilization: 0.85, ... })
#   trace.snapshots  # => [{ t: 0.0, instances: 5, ... }, { t: 60.0, ... }]
#
# @example As Loop observer
#   loop = Skaler::Loop.new(..., observer: trace)
#   loop.step  # trace.on_step called automatically
class Skaler::Trace
  attr_reader :snapshots

  def initialize
    @snapshots = []
  end

  # Record a snapshot at the given virtual time.
  #
  # @param time [Float] virtual seconds
  # @param metrics [Hash] snapshot fields (utilization, instances, queue depth, etc.)
  def record(time, metrics)
    @snapshots << metrics.merge(t: time)
  end

  # Loop observer callback. Translates control-loop output to the snapshot format.
  #
  # The snapshot can be augmented by the caller after this method returns by
  # mutating `snapshots.last` (e.g. to add simulator-specific fields like
  # arrivals, cost tracking).
  #
  # @param time [Float] virtual time
  # @param measurements [Hash] sensor readings
  # @param controller_state [Hash] PID terms, utilization, etc.
  # @param delta [Integer] scaling delta
  # @param result [Symbol] actuator result
  def on_step(time:, measurements:, controller_state:, delta:, result:)
    scale_command = case result
    when :scaled_up then "+#{delta}"
    when :scaled_down then "-#{delta.abs}"
    end

    snapshot = {
      t: time,
      utilization: controller_state[:smoothed_utilization],
      raw_utilization: controller_state[:raw_utilization],
      error: controller_state[:error],
      p: controller_state[:p],
      i: controller_state[:i],
      d: controller_state[:d],
      output: controller_state[:output],
      instances: measurements[:active_workers],
      active_workers: measurements[:active_workers],
      busy_threads: measurements[:busy_threads],
      free_threads: measurements[:capacity].to_i - measurements[:busy_threads].to_i,
      ready_queue_depth: measurements[:ready_queue_depth],
      scale_command: scale_command,
      pg_headroom: controller_state[:headroom_pg],
      redis_headroom: controller_state[:headroom_redis]
    }

    @snapshots << snapshot
  end

  # @return [Integer] number of snapshots recorded
  def size
    @snapshots.size
  end
end
