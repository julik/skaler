# Production actuator that delegates to Skaler::ScaleExecutor for Render API calls.
#
# Wraps the existing ScaleExecutor to provide the Actuator interface.
# Cooldown, boot-lag tracking, and Render API calls are handled by ScaleExecutor.
#
# @example
#   actuator = Skaler::RenderActuator.new(
#     executor: Skaler::ScaleExecutor.new(render_client: client),
#     service_id: "srv-abc123",
#     min_instances: 5,
#     max_instances: 40,
#     cooldown_up: 60,
#     cooldown_down: 120
#   )
#   actuator.scale(3)  # => :scaled_up
class Skaler::RenderActuator < Skaler::Actuator
  # @param executor [Skaler::ScaleExecutor] the scale executor
  # @param service_id [String] Render service ID
  # @param min_instances [Integer] minimum instance count
  # @param max_instances [Integer] maximum instance count
  # @param cooldown_up [Integer] cooldown seconds after scale-up
  # @param cooldown_down [Integer] cooldown seconds after scale-down
  def initialize(executor:, service_id:, min_instances:, max_instances:, cooldown_up:, cooldown_down:)
    @executor = executor
    @service_id = service_id
    @min_instances = min_instances
    @max_instances = max_instances
    @cooldown_up = cooldown_up
    @cooldown_down = cooldown_down
  end

  # Execute a scaling action via Render API.
  #
  # @param delta [Integer] signed delta
  # @return [Symbol] :scaled_up, :scaled_down, :noop, or :cooldown
  def scale(delta)
    return :noop if delta == 0

    cooldown = (delta > 0) ? @cooldown_up : @cooldown_down
    return :cooldown if @executor.in_cooldown?(cooldown_seconds: cooldown)

    current = @executor.instance_count(service_id: @service_id)

    if delta > 0
      return :cooldown unless @executor.can_scale_up?(active_sq_workers: current)
      target = [current + delta, @max_instances].min
      return :noop if target <= current
      @executor.scale_to(target: target, service_id: @service_id, current_instances: current)
      :scaled_up
    else
      target = [current + delta, @min_instances].max # delta is negative
      return :noop if target >= current
      @executor.scale_to(target: target, service_id: @service_id, current_instances: current)
      :scaled_down
    end
  end
end
