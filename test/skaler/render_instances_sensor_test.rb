require "test_helper"

class Skaler::RenderInstancesSensorTest < Skaler::TestCase
  test "take_measurement delegates to render_client" do
    sensor = Skaler::RenderInstancesSensor.new(render_client: FakeRenderClient.new(12), service_id: "srv-test")
    assert_equal 12, sensor.take_measurement
  end

  class FakeRenderClient
    def initialize(count)
      @count = count
    end

    def instance_count(service_id:)
      @count
    end
  end
end
