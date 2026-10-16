# Sensors that read SolidQueue tables and the ActiveRecord pool. Require this
# from a booted Rails app - it expects `SolidQueue` and `ActiveRecord::Base` to be loaded.
require_relative "../skaler"

require_relative "active_workers_sensor"
require_relative "threads_per_worker_sensor"
require_relative "capacity_sensor"
require_relative "claimed_jobs_sensor"
require_relative "completed_jobs_sensor"
require_relative "ready_jobs_sensor"
require_relative "pg_connections_sensor"
require_relative "pg_connection_cap_sensor"
