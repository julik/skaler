require "solid_queue_test_helper"

class Skaler::CapacitySensorTest < Skaler::SolidQueueTestCase
  test "returns product of active workers and threads per worker" do
    sensor = Skaler::CapacitySensor.new

    sensor.instance_variable_get(:@workers_sensor).stub(:take_measurement, 8) do
      sensor.instance_variable_get(:@threads_sensor).stub(:take_measurement, 5) do
        assert_equal 40, sensor.take_measurement
      end
    end
  end

  test "returns zero when no workers" do
    sensor = Skaler::CapacitySensor.new

    sensor.instance_variable_get(:@workers_sensor).stub(:take_measurement, 0) do
      sensor.instance_variable_get(:@threads_sensor).stub(:take_measurement, 5) do
        assert_equal 0, sensor.take_measurement
      end
    end
  end

  test "reads both values from SolidQueue process rows" do
    2.times { add_worker(metadata: {"thread_pool_size" => 10}) }
    assert_equal 20, Skaler::CapacitySensor.new.take_measurement
  end
end
