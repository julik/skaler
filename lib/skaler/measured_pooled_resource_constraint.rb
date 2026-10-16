# Closed-loop constraint for a pooled resource, sized from the measured usage
# rather than from a per-worker estimate.
#
# {Skaler::PooledResourceConstraint} models demand as `workers x pool_per_worker`.
# For Redis that model is structurally wrong: connection pools fill lazily, so an
# instance's footprint grows with load and no single constant holds at both idle
# and saturation. See `REDIS_POOL_PER_WORKER` in EXAMPLE_CONFIG.md for the incident
# history. This constraint reads what the resource reports and hands out only the
# slack that is left under `target_utilization`.
#
# Fails closed: an unreadable measurement yields zero headroom, because assuming
# room is what exhausts the resource.
#
# @example Redis clients, capped at 75% of maxclients
#   Skaler::MeasuredPooledResourceConstraint.new(
#     usage: 620, cap: 1000, pool_per_worker: 20,
#     target_utilization: 0.75, name: :redis
#   )
class Skaler::MeasuredPooledResourceConstraint < Skaler::Constraint
  # @param usage [Integer, #call, nil] units currently in use (nil = unknown)
  # @param cap [Integer, #call, nil] hard limit the resource enforces
  # @param pool_per_worker [Integer] units one more worker is expected to add
  # @param target_utilization [Float] fraction of cap the fleet may occupy
  # @param name [Symbol] for reporting (e.g. :redis)
  def initialize(usage:, cap:, pool_per_worker:, target_utilization:, name:)
    @usage = usage
    @cap = cap
    @pool_per_worker = pool_per_worker
    @target_utilization = target_utilization
    @name = name
  end

  # @param active_workers [Integer] ignored — headroom comes from the measurement,
  #   not from a worker count, so the two cannot drift out of sync
  # @return [Hash] { max_additional:, headroom_<name>:, <name>_utilization: }
  def evaluate(active_workers:)
    usage = resolve(@usage)
    cap = resolve(@cap)
    return fail_closed if usage.nil? || cap.nil? || cap <= 0 || @pool_per_worker.to_i <= 0

    # Signed: a negative headroom means the fleet is already over budget, which
    # is worth reporting rather than flattening to zero.
    headroom = ((cap * @target_utilization).floor - usage) / @pool_per_worker

    {
      max_additional: [headroom, 0].max,
      "headroom_#{@name}": headroom,
      "#{@name}_utilization": usage.to_f / cap
    }
  end

  private

  def fail_closed
    {max_additional: 0, "headroom_#{@name}": 0, "#{@name}_utilization": 0.0}
  end

  def resolve(value)
    value.respond_to?(:call) ? value.call : value
  end
end
