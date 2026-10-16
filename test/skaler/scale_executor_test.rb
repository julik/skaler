require "test_helper"
require_relative "../support/fake_redis"

class Skaler::ScaleExecutorTest < Skaler::TestCase
  class FakeRenderClient
    Service = Struct.new(:id, :name)
    ServiceEnvelope = Struct.new(:service)

    attr_reader :scale_calls
    attr_accessor :fail_scaling

    def initialize
      @scale_calls = []
    end

    def services
      [ServiceEnvelope.new(Service.new("srv-web", "web")), ServiceEnvelope.new(Service.new("srv-wrk", "worker"))]
    end

    def instance_count(service_id:) = 4

    def scale_service(service_id:, instance_count:)
      raise "Render said no" if fail_scaling
      @scale_calls << [service_id, instance_count]
    end
  end

  PREFIX = Skaler::ScaleExecutor::REDIS_PREFIX

  setup do
    @redis = FakeRedis.new
    @render = FakeRenderClient.new
    @events = []
    @executor = Skaler::ScaleExecutor.new(
      render_client: @render,
      redis: @redis,
      boot_lag_timeout: 180,
      max_consecutive_failures: 2,
      backoff_seconds: 600,
      on_scale: ->(**event) { @events << event }
    )
  end

  test "find_service_id looks the service up by name" do
    assert_equal "srv-wrk", @executor.find_service_id(service_name: "worker")
    assert_nil @executor.find_service_id(service_name: "nope")
  end

  test "scale_to commands Render and reports the change" do
    assert @executor.scale_to(target: 6, service_id: "srv-wrk", current_instances: 4)
    assert_equal [["srv-wrk", 6]], @render.scale_calls
    assert_equal 1, @events.size
    assert_equal 2, @events.first[:by_n]
    assert_equal "up", @events.first[:direction]
  end

  test "scale_to swallows Render errors and returns false" do
    @render.fail_scaling = true
    refute @executor.scale_to(target: 6, service_id: "srv-wrk", current_instances: 4)
    assert_empty @events
  end

  test "a scale-up blocks further scale-ups until the instances arrive" do
    @executor.scale_to(target: 6, service_id: "srv-wrk", current_instances: 4)
    refute @executor.can_scale_up?(active_sq_workers: 4)

    @executor.record_tick(active_sq_workers: 6)
    assert @executor.can_scale_up?(active_sq_workers: 6)
  end

  test "a scale-down does not leave a pending target" do
    @executor.scale_to(target: 2, service_id: "srv-wrk", current_instances: 4)
    assert @executor.can_scale_up?(active_sq_workers: 2)
    assert_equal "down", @events.first[:direction]
  end

  test "repeated boot timeouts put the executor into backoff" do
    2.times do
      @executor.scale_to(target: 6, service_id: "srv-wrk", current_instances: 4)
      @redis.set("#{PREFIX}:pending_since", Time.now.to_f - 181) # instances never showed up
      @executor.record_tick(active_sq_workers: 4)
    end

    refute @executor.can_scale_up?(active_sq_workers: 4), "Two timeouts with max_consecutive_failures=2 must back off"
  end

  test "in_cooldown? sees decisions inside the window" do
    refute @executor.in_cooldown?(cooldown_seconds: 60)
    @executor.scale_to(target: 5, service_id: "srv-wrk", current_instances: 4)
    assert @executor.in_cooldown?(cooldown_seconds: 60)
  end
end
