require "test_helper"

class Skaler::SensorTest < Skaler::TestCase
  test "base class raises NotImplementedError for take_measurement" do
    assert_raises(NotImplementedError) { Skaler::Sensor.new.take_measurement }
  end

  test ".from factory creates a working sensor" do
    counter = 0
    sensor = Skaler::Sensor.from { counter += 1 }

    assert_equal 1, sensor.take_measurement
    assert_equal 2, sensor.take_measurement
  end

  test ".from sensor is a Skaler::Sensor subclass" do
    sensor = Skaler::Sensor.from { 42 }
    assert_kind_of Skaler::Sensor, sensor
  end
end
