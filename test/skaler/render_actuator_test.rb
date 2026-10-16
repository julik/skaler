require "test_helper"

class Skaler::RenderActuatorTest < Skaler::TestCase
  class FakeExecutor
    attr_accessor :current_instance_count, :scaled_to, :cooldown, :can_scale

    def initialize(instance_count: 5)
      @current_instance_count = instance_count
      @scaled_to = nil
      @cooldown = false
      @can_scale = true
    end

    def instance_count(service_id:)
      @current_instance_count
    end

    def in_cooldown?(cooldown_seconds:)
      @cooldown
    end

    def can_scale_up?(active_sq_workers:)
      @can_scale
    end

    def scale_to(target:, service_id:, current_instances:)
      @scaled_to = target
      true
    end
  end

  setup do
    @executor = FakeExecutor.new
    @actuator = Skaler::RenderActuator.new(
      executor: @executor,
      service_id: "srv-test",
      min_instances: 2,
      max_instances: 20,
      cooldown_up: 60,
      cooldown_down: 120
    )
  end

  test "scale up delegates to executor" do
    result = @actuator.scale(3)
    assert_equal :scaled_up, result
    assert_equal 8, @executor.scaled_to
  end

  test "scale down delegates to executor" do
    result = @actuator.scale(-2)
    assert_equal :scaled_down, result
    assert_equal 3, @executor.scaled_to
  end

  test "scale up respects max_instances" do
    @actuator.scale(20)
    assert_equal 20, @executor.scaled_to
  end

  test "scale down respects min_instances" do
    @actuator.scale(-10)
    assert_equal 2, @executor.scaled_to
  end

  test "returns cooldown when executor is in cooldown" do
    @executor.cooldown = true
    assert_equal :cooldown, @actuator.scale(3)
  end

  test "returns cooldown when executor cannot scale up" do
    @executor.can_scale = false
    assert_equal :cooldown, @actuator.scale(3)
  end

  test "returns noop for zero delta" do
    assert_equal :noop, @actuator.scale(0)
  end

  test "returns noop when clamped to current count" do
    @executor.current_instance_count = 20
    result = @actuator.scale(5)
    assert_equal :noop, result
  end
end
