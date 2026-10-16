# Reads the Redis maxclients setting from Redis INFO.
#
# @example
#   sensor = Skaler::RedisConnectionCapSensor.new(redis: Redis.new)
#   sensor.take_measurement # => 10000
class Skaler::RedisConnectionCapSensor < Skaler::Sensor
  # @param redis [Redis] Redis client
  def initialize(redis:)
    @redis = redis
  end

  def take_measurement
    info = @redis.info("clients")
    info["maxclients"].to_i
  end
end
