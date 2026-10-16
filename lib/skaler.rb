require "json"
require "logger"
require_relative "skaler/version"

# A PID-driven autoscaler for background job workers, plus a discrete-event
# simulator for tuning it. See README.md for the overview.
module Skaler
  class << self
    attr_writer :logger

    # @return [Logger] where the controller and executor report skipped ticks and failures
    def logger
      @logger ||= Logger.new($stderr, level: Logger::WARN, progname: "skaler")
    end
  end
end

# Base classes first - the rest subclass them with compact `Skaler::X < Skaler::Y` syntax
require_relative "skaler/sensor"
require_relative "skaler/constraint"
require_relative "skaler/actuator"
require_relative "skaler/metric_store"

require_relative "skaler/memory_metric_store"
require_relative "skaler/redis_metric_store"
require_relative "skaler/pid_controller"
require_relative "skaler/controller"
require_relative "skaler/loop"
require_relative "skaler/trace"

require_relative "skaler/pooled_resource_constraint"
require_relative "skaler/measured_pooled_resource_constraint"
require_relative "skaler/max_instances_constraint"
require_relative "skaler/slew_rate_constraint"

require_relative "skaler/redis_connections_sensor"
require_relative "skaler/redis_connection_cap_sensor"
require_relative "skaler/render_instances_sensor"
require_relative "skaler/scale_executor"
require_relative "skaler/render_actuator"

require_relative "skaler/sorted_heap"
require_relative "skaler/event_queue"
require_relative "skaler/distribution"
require_relative "skaler/job_type"
require_relative "skaler/arrival_process"
require_relative "skaler/worker_pool"
require_relative "skaler/simulated_actuator"
require_relative "skaler/simulator"
require_relative "skaler/builder"
require_relative "skaler/job_profile"
require_relative "skaler/ingress_profile"
require_relative "skaler/progress_reporter"
require_relative "skaler/svg_chart"
