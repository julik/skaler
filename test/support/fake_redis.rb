# Minimal sorted-set fake for testing without a real Redis connection.
class FakeRedis
  def initialize
    @sets = Hash.new { |h, k| h[k] = [] } # key => [[score, member], ...]
  end

  def time
    t = Time.now
    [t.to_i, t.usec]
  end

  def zadd(key, score, member)
    @sets[key] << [score.to_f, member]
    @sets[key].sort_by!(&:first)
  end

  def zrangebyscore(key, min, max, **opts)
    min_f = (min == "-inf") ? -Float::INFINITY : min.to_f
    max_f = (max == "+inf") ? Float::INFINITY : max.to_f
    result = @sets[key].select { |s, _| s.between?(min_f, max_f) }.map(&:last)
    if (limit = opts[:limit])
      offset, count = limit
      result = result[offset, count] || []
    end
    result
  end

  def zrevrangebyscore(key, max, min, **opts)
    min_f = (min == "-inf") ? -Float::INFINITY : min.to_f
    max_f = (max == "+inf") ? Float::INFINITY : max.to_f
    result = @sets[key].select { |s, _| s.between?(min_f, max_f) }.map(&:last).reverse
    if (limit = opts[:limit])
      offset, count = limit
      result = result[offset, count] || []
    end
    result
  end

  def zremrangebyscore(key, min, max)
    min_f = (min == "-inf") ? -Float::INFINITY : min.to_f
    max_f = (max == "+inf") ? Float::INFINITY : max.to_f
    @sets[key].reject! { |s, _| s.between?(min_f, max_f) }
  end

  def get(key)
    @kv ||= {}
    @kv[key]
  end

  def set(key, value, ex: nil)
    @kv ||= {}
    @kv[key] = value
  end

  def expire(key, seconds)
    # no-op for tests
  end

  def del(key)
    @kv ||= {}
    @kv.delete(key)
  end

  def info(section)
    @info ||= {}
    @info.fetch(section, {})
  end

  def stub_info(section, values)
    @info ||= {}
    @info[section] = values
  end
end
