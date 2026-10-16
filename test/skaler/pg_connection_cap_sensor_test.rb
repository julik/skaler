require "solid_queue_test_helper"

class Skaler::PgConnectionCapSensorTest < Skaler::SolidQueueTestCase
  test "returns conservative cap when host does not include bouncer" do
    sensor = Skaler::PgConnectionCapSensor.new(pg_connection_cap: 2000)
    assert_equal 350, sensor.take_measurement
  end

  test "returns pooled cap when host includes bouncer" do
    with_db_config(host: "app-pgbouncer-private", port: 5432) do
      assert_equal 2000, Skaler::PgConnectionCapSensor.new(pg_connection_cap: 2000).take_measurement
    end
  end

  test "returns pooled cap when port is the managed pooler port" do
    with_db_config(host: "dpg-abc123-a.frankfurt-postgres.render.com", port: 6432) do
      assert_equal 2000, Skaler::PgConnectionCapSensor.new(pg_connection_cap: 2000).take_measurement
    end
  end

  test "returns conservative cap for a direct connection" do
    with_db_config(host: "dpg-abc123-a.frankfurt-postgres.render.com", port: 5432) do
      assert_equal 350, Skaler::PgConnectionCapSensor.new(pg_connection_cap: 2000).take_measurement
    end
  end

  test "returns conservative cap when the port is not set" do
    with_db_config(host: "dpg-abc123-a.frankfurt-postgres.render.com", port: nil) do
      assert_equal 350, Skaler::PgConnectionCapSensor.new(pg_connection_cap: 2000).take_measurement
    end
  end

  private

  # Runs the block with ActiveRecord reporting the given host/port as its database config.
  def with_db_config(host:, port:)
    db_config = FakeActiveRecord::DbConfig.new(
      host: host, configuration_hash: {adapter: "postgresql", database: "app_test", host: host, port: port}
    )
    ActiveRecord::Base.stub(:connection_db_config, db_config) { yield }
  end
end
