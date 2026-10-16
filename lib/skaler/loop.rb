# The control-loop coordinator.
#
# Glues sensors, metric store, controller, and actuator into a single step.
# No logic of its own — just orchestration. Works identically in simulation and
# production with different implementations plugged in.
#
# Step order (strict):
#   1. Read all sensors ONCE → measurements hash
#   2. Store measurements in MetricStore
#   3. Controller computes delta from store state
#   4. Actuator executes delta (if non-zero)
#   5. Observer notified (optional, for tracing)
#
# @example
#   loop = Skaler::Loop.new(
#     sensors: { active_workers: worker_sensor, capacity: cap_sensor },
#     store: Skaler::MemoryMetricStore.new(clock: -> { time }),
#     controller: controller,
#     actuator: actuator,
#     observer: trace
#   )
#   result = loop.step # => :scaled_up, :scaled_down, :noop, or :cooldown
class Skaler::Loop
  # @param sensors [Hash{Symbol => Skaler::Sensor}] sensors keyed by measurement name
  # @param store [Skaler::MetricStore] metric storage backend
  # @param controller [Skaler::Controller] computes scaling delta
  # @param actuator [Skaler::Actuator] executes scaling commands
  # @param observer [#on_step, nil] optional observer for tracing/logging
  def initialize(sensors:, store:, controller:, actuator:, observer: nil)
    @sensors = sensors
    @store = store
    @controller = controller
    @actuator = actuator
    @observer = observer
  end

  # Execute one control-loop step.
  #
  # @return [Symbol] actuator result (:scaled_up, :scaled_down, :noop, :cooldown)
  def step
    measurements = @sensors.transform_values(&:take_measurement)
    @store.record(measurements)
    delta = @controller.step(@store)
    result = (delta != 0) ? @actuator.scale(delta) : :noop
    @observer&.on_step(
      time: @store.now,
      measurements: measurements,
      controller_state: @controller.last_state,
      delta: delta,
      result: result
    )
    result
  end
end
