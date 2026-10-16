# Constraint for pooled resources (PG connections, Redis connections).
#
# Given a connection cap and per-worker pool size, computes how many
# additional workers can be added before exhausting the pool. One class
# serves both PG and Redis — instantiate with different parameters.
#
# The cap can be a fixed Integer or a callable (Proc/lambda) for runtime
# resolution (e.g. querying Redis INFO or checking PgBouncer presence).
# Pass a cap that already accounts for any safety margins you want.
#
# @example PG constraint with fixed cap
#   Skaler::PooledResourceConstraint.new(cap: 2000, pool_per_worker: 7, name: :pg)
#
# @example Redis constraint with dynamic cap
#   Skaler::PooledResourceConstraint.new(
#     cap: -> { redis.info("clients")["maxclients"].to_i },
#     pool_per_worker: 10,
#     name: :redis
#   )
class Skaler::PooledResourceConstraint < Skaler::Constraint
  # @param cap [Integer, #call] connection capacity — fixed value or callable
  # @param pool_per_worker [Integer] connections consumed per worker
  # @param name [Symbol] for reporting (e.g. :pg or :redis)
  def initialize(cap:, pool_per_worker:, name:)
    @cap = cap
    @pool_per_worker = pool_per_worker
    @name = name
  end

  # @param active_workers [Integer] current number of active workers
  # @return [Hash] { max_additional: Integer, headroom_<name>: Integer }
  def evaluate(active_workers:)
    cap = @cap.respond_to?(:call) ? @cap.call : @cap
    return {max_additional: 0, "headroom_#{@name}": 0} if @pool_per_worker.to_i <= 0
    max_workers = cap / @pool_per_worker
    headroom = max_workers - active_workers

    {max_additional: [headroom, 0].max, "headroom_#{@name}": headroom}
  end
end
