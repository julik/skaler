require "test_helper"
require_relative "../support/fake_redis"

class Skaler::RedisConnectionsSensorTest < Skaler::TestCase
  setup do
    @redis = FakeRedis.new
    @redis.stub_info("clients", {"connected_clients" => "47", "maxclients" => "1000"})
  end

  test "reads connected_clients from INFO" do
    assert_equal 47, Skaler::RedisConnectionsSensor.new(redis: @redis).take_measurement
  end

  test "reads maxclients from INFO" do
    assert_equal 1000, Skaler::RedisConnectionCapSensor.new(redis: @redis).take_measurement
  end
end
