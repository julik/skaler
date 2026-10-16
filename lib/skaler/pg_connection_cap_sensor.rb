# Returns the effective PG connection cap.
#
# Uses a higher cap (default 2000) when a connection pooler is detected in the
# DATABASE_URL, otherwise falls back to a conservative 350.
#
# @example
#   sensor = Skaler::PgConnectionCapSensor.new(pg_connection_cap: 2000)
#   sensor.take_measurement # => 2000 (if a pooler is detected) or 350
class Skaler::PgConnectionCapSensor < Skaler::Sensor
  DIRECT_PG_CONNECTION_CAP = 350
  RENDER_POOLER_PORT = 6432

  # @param pg_connection_cap [Integer] cap when a connection pooler is present
  def initialize(pg_connection_cap: 2000)
    @pg_connection_cap = pg_connection_cap
  end

  def take_measurement
    db_config = ActiveRecord::Base.connection_db_config
    # Two signals because poolers announce themselves differently: our own PgBouncer private
    # service is recognised by hostname, Render's managed pooler by its 6432 port.
    if db_config.host.to_s.include?("bouncer") || db_config.configuration_hash[:port].to_i == RENDER_POOLER_PORT
      @pg_connection_cap
    else
      DIRECT_PG_CONNECTION_CAP
    end
  end
end
