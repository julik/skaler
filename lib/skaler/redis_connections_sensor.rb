# Reads current Redis connection count from Redis INFO.
#
# @example
#   sensor = Skaler::RedisConnectionsSensor.new(redis: Redis.new)
#   sensor.take_measurement # => 47
class Skaler::RedisConnectionsSensor < Skaler::Sensor
  # @param redis [Redis] Redis client
  def initialize(redis:)
    @redis = redis
  end

  def take_measurement
    info = @redis.info("clients")
    info["connected_clients"].to_i
  end
end
