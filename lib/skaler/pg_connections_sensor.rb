# Estimates current PG connection usage as active_workers * pool_size.
#
# With PgBouncer in transaction mode, pg_stat_activity is meaningless,
# so we estimate based on what we know.
#
# @example
#   sensor = Skaler::PgConnectionsSensor.new
#   sensor.take_measurement # => 56  (8 workers * 7 pool_size)
class Skaler::PgConnectionsSensor < Skaler::Sensor
  def take_measurement
    active_workers = Skaler::ActiveWorkersSensor.live_workers.count
    pool_size = ActiveRecord::Base.connection_pool.size
    active_workers * pool_size
  end
end
