# Counts ready-to-execute jobs, filtered to worker-relevant queues and excluding paused queues.
#
# @example
#   sensor = Skaler::ReadyJobsSensor.new
#   sensor.take_measurement # => 15
class Skaler::ReadyJobsSensor < Skaler::Sensor
  # @param model [Class] ActiveRecord model over `solid_queue_ready_executions`
  #   (defaults to `SolidQueue::ReadyExecution`; pass a read-only subclass if you have one)
  def initialize(model: nil)
    @model = model
  end

  def take_measurement
    worker_queues = extract_worker_queues
    paused_queue_names = SolidQueue::Pause.pluck(:queue_name)

    scope = (@model || SolidQueue::ReadyExecution).all
    scope = scope.where(queue_name: worker_queues) if worker_queues
    scope = scope.where.not(queue_name: paused_queue_names) if paused_queue_names.any?
    scope.count
  end

  private

  def extract_worker_queues
    workers = Skaler::ActiveWorkersSensor.live_workers.to_a

    queue_names = workers.filter_map { |w|
      w.metadata["queues"] if w.metadata.is_a?(Hash) && !w.metadata["queues"].to_s.empty?
    }.flat_map { |q| q.split(",") }.uniq

    queue_names unless queue_names.empty?
  end
end
