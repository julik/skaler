# Reads the current instance count from the Render API.
#
# @example
#   sensor = Skaler::RenderInstancesSensor.new(
#     render_client: RenderClient.new,
#     service_id: "srv-abc123"
#   )
#   sensor.take_measurement # => 12
class Skaler::RenderInstancesSensor < Skaler::Sensor
  # @param render_client [RenderClient] Render API client
  # @param service_id [String] Render service ID
  def initialize(render_client:, service_id:)
    @render_client = render_client
    @service_id = service_id
  end

  def take_measurement
    @render_client.instance_count(service_id: @service_id)
  end
end
