# Executes scaling decisions via the Render API with boot lag tracking and failure backoff.
#
# Tracks pending scale-up commands and waits for new instances to actually appear
# (measured by active_sq_workers reaching the target). If instances fail to materialize
# within boot_lag_timeout, increments a failure counter. After max_consecutive_failures,
# enters a backoff period where scale-ups are blocked.
#
# Scale-downs are always allowed (no boot lag concern).
#
# State is stored in Redis under `solid_queue:autoscaler:executor:*` keys.
#
# Every successful scale command is reported to the optional `on_scale` callable
# with `by_n:`, `direction:` and `timestamp:` keywords - hook metrics or Slack in there.
#
# @example
#   executor = Skaler::ScaleExecutor.new(render_client: RenderClient.new, redis: Redis.new)
#   service_id = executor.find_service_id(service_name: "my-worker")
#   if executor.can_scale_up?(active_sq_workers: 10)
#     executor.scale_to(target: 12, service_id: service_id, active_sq_workers: 10)
#   end
class Skaler::ScaleExecutor
  REDIS_PREFIX = "solid_queue:autoscaler:executor"
  DECISIONS_KEY = "solid_queue:autoscaler:decisions"
  HISTORY_TTL = 1800

  # @param render_client [#services, #instance_count, #scale_service] Render API client
  # @param redis [Redis] Redis client for state storage
  # @param boot_lag_timeout [Integer] Seconds to wait for instances to appear (default: 180)
  # @param max_consecutive_failures [Integer] Failures before entering backoff (default: 3)
  # @param backoff_seconds [Integer] Duration of backoff period (default: 600)
  # @param on_scale [#call, nil] called with `by_n:, direction:, timestamp:` after each scale command
  def initialize(render_client:, redis:, boot_lag_timeout: 180,
    max_consecutive_failures: 3, backoff_seconds: 600, on_scale: nil)
    @render_client = render_client
    @redis = redis
    @on_scale = on_scale
    @boot_lag_timeout = boot_lag_timeout
    @max_consecutive_failures = max_consecutive_failures
    @backoff_seconds = backoff_seconds
  end

  # Find the Render service ID by name.
  #
  # Errors from the Render API (e.g. Unauthorized on a bad token) propagate so
  # the outer control-loop rescue reports them to AppSignal — a silent nil here
  # disables autoscaling without alerting.
  #
  # @param service_name [String] The service name to search for
  # @return [String, nil] The service ID or nil if the service is not in the response
  def find_service_id(service_name:)
    services = render_client.services
    service = services.find { |s| s.service.name == service_name }&.service
    service&.id
  end

  # Get the current instance count for a service.
  #
  # @param service_id [String] Render service ID
  # @return [Integer] Current instance count
  def instance_count(service_id:)
    render_client.instance_count(service_id: service_id)
  end

  # Whether a scale-up is currently allowed.
  #
  # Returns false if instances are still booting (pending target not yet reached)
  # or if we're in a backoff period after repeated failures.
  #
  # @param active_sq_workers [Integer] Current number of active workers
  # @return [Boolean]
  def can_scale_up?(active_sq_workers:)
    return false if pending_scale_up?
    return false if in_backoff?
    true
  end

  # Command a scale to a specific target instance count.
  #
  # Records the pending target for boot lag tracking and stores a decision
  # for cooldown enforcement. Pending is determined by comparing target to
  # current_instances (Render count), not active_sq_workers (SQ heartbeats),
  # because workers can lag behind instance count during boot.
  #
  # @param target [Integer] Desired instance count
  # @param service_id [String] Render service ID
  # @param current_instances [Integer] Current Render instance count
  # @return [Boolean] true if scale command succeeded
  def scale_to(target:, service_id:, current_instances:)
    render_client.scale_service(service_id: service_id, instance_count: target)

    # Track pending scale-up for boot lag detection
    if target > current_instances
      redis.set("#{REDIS_PREFIX}:pending_target", target)
      redis.set("#{REDIS_PREFIX}:pending_since", Time.now.to_f)
    end

    # Record decision for cooldown
    now = Time.now.to_f
    redis.zadd(DECISIONS_KEY, now, "scale:#{target}:#{now}")
    redis.zremrangebyscore(DECISIONS_KEY, "-inf", now - HISTORY_TTL)

    # Emit scaling event for metrics and downstream listeners (e.g. Slack)
    delta = target - current_instances
    autoscaler_instance_change(delta)

    true
  rescue => e
    Skaler.logger.error "[Skaler::ScaleExecutor] Error scaling service: #{e.message}"
    false
  end

  # Called every tick to check whether pending instances have materialized.
  #
  # If active_sq_workers >= pending_target, clears pending state and resets failures.
  # If boot_lag_timeout exceeded, increments consecutive failures and may enter backoff.
  #
  # @param active_sq_workers [Integer] Current active worker count
  def record_tick(active_sq_workers:)
    return unless pending_scale_up?

    pending_target = redis.get("#{REDIS_PREFIX}:pending_target").to_i
    pending_since = redis.get("#{REDIS_PREFIX}:pending_since").to_f

    if active_sq_workers >= pending_target
      # Instances arrived successfully
      clear_pending!
      reset_failures!
      Skaler.logger.info "[Skaler::ScaleExecutor] Pending instances arrived (target=#{pending_target}, active=#{active_sq_workers})"
    elsif Time.now.to_f - pending_since > @boot_lag_timeout
      # Timed out waiting for instances
      clear_pending!
      failures = increment_failures!
      Skaler.logger.error "[Skaler::ScaleExecutor] Boot lag timeout — instances never arrived (target=#{pending_target}, active=#{active_sq_workers}, failures=#{failures})"

      if failures >= @max_consecutive_failures
        enter_backoff!
        Skaler.logger.error "[Skaler::ScaleExecutor] Entering backoff for #{@backoff_seconds}s after #{failures} consecutive failures"
      end
    end
  end

  # Check if there's a recent scaling decision within the cooldown window.
  #
  # @param cooldown_seconds [Integer] Cooldown window in seconds
  # @return [Boolean]
  def in_cooldown?(cooldown_seconds:)
    now = Time.now.to_f
    recent = redis.zrangebyscore(DECISIONS_KEY, now - cooldown_seconds, now)
    recent.any?
  end

  private

  # @param by_n [Integer] signed delta - positive for scale-up, negative for scale-down
  def autoscaler_instance_change(by_n)
    return unless @on_scale
    @on_scale.call(by_n: by_n, direction: (by_n > 0) ? "up" : "down", timestamp: Time.now)
  end

  attr_reader :render_client, :redis

  def pending_scale_up?
    !redis.get("#{REDIS_PREFIX}:pending_target").to_s.empty?
  end

  def clear_pending!
    redis.del("#{REDIS_PREFIX}:pending_target")
    redis.del("#{REDIS_PREFIX}:pending_since")
  end

  def consecutive_failures
    redis.get("#{REDIS_PREFIX}:consecutive_failures").to_i
  end

  def increment_failures!
    count = consecutive_failures + 1
    redis.set("#{REDIS_PREFIX}:consecutive_failures", count)
    count
  end

  def reset_failures!
    redis.del("#{REDIS_PREFIX}:consecutive_failures")
  end

  def in_backoff?
    backoff_until = redis.get("#{REDIS_PREFIX}:backoff_until")
    return false unless backoff_until
    Time.now.to_f < backoff_until.to_f
  end

  def enter_backoff!
    redis.set("#{REDIS_PREFIX}:backoff_until", (Time.now.to_f + @backoff_seconds).to_s)
  end
end
