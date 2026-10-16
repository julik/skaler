# Loads a per-minute ingress timeseries CSV and produces simulator-ready
# scheduled arrival events and job type definitions.
#
# The CSV format has a timestamp column followed by one column per job class,
# with integer enqueue counts per minute:
#
#   timestamp,SyncMailboxJob,ProcessWebhookJob,FetchMessageJob
#   2026-10-12T06:00:00Z,3341,620,1218
#   2026-10-12T06:01:00Z,401,551,143
#
# Each non-zero cell becomes a scheduled arrival batch at that minute offset.
# Job types use a default 0.5–2s flat duration unless a separate durations CSV
# is provided via `--durations`.
#
# The durations CSV has the format (action names use AppSignal's `Class#method`
# convention, e.g. `FetchMessageJob#perform`):
#
#   action,mean_ms,p90_ms
#   SyncMailboxJob#perform,640.00,1150.00
#   FetchMessageJob#perform,410.00,1290.00
#
# @example Load and run a simulation from per-minute AppSignal data
#   ingress = Skaler::IngressProfile.from_csv("examples/enqueues_per_minute.csv")
#
#   sim = Skaler::Simulator.new(
#     job_types: ingress.job_types,
#     arrival_process: ingress.arrival_process_config,
#     pid_config: { ... },
#     pool_config: { ... },
#     constraints: { ... },
#     timing: { autoscaler_interval: 60, max_time: ingress.max_time, ... },
#     random_seed: 42
#   )
#   trace = sim.run
#
# @example With a separate durations CSV
#   ingress = Skaler::IngressProfile.from_csv(
#     "examples/enqueues_per_minute.csv",
#     durations_csv: "examples/job_durations.csv"
#   )
class Skaler::IngressProfile
  attr_reader :job_types, :max_time

  DEFAULT_DURATION = ->(rng) { rng.rand(0.5..2.0) }

  # Parse a per-minute ingress CSV into an IngressProfile.
  #
  # @param csv_path [String] path to CSV with timestamp + job class columns
  # @param durations_csv [String, nil] path to CSV with action,mean_ms,p90_ms
  # @return [Skaler::IngressProfile]
  def self.from_csv(csv_path, durations_csv: nil)
    require "csv"
    rows = CSV.read(csv_path, headers: true)
    durations = durations_csv ? CSV.read(durations_csv, headers: true) : nil
    new(rows, durations: durations)
  end

  # @param rows [CSV::Table] parsed ingress CSV rows
  # @param durations [CSV::Table, nil] parsed durations CSV rows
  def initialize(rows, durations: nil)
    @rows = rows
    @durations = build_duration_lookup(durations)
    build!
  end

  # Hash suitable for passing as the `arrival_process:` argument to {Skaler::Simulator}.
  #
  # @return [Hash] scheduled arrival process configuration
  def arrival_process_config
    {
      mode: :scheduled,
      schedule: @schedule,
      default_type: @job_class_names.first
    }
  end

  private

  def build!
    headers = @rows.headers
    job_columns = headers - ["timestamp"]
    @job_class_names = job_columns.map { |col| symbolize(col) }

    # Build job types
    @job_types = {}
    job_columns.each_with_index do |col, i|
      sym = @job_class_names[i]
      duration = find_duration(col)
      @job_types[sym] = Skaler::JobType.new(name: sym, duration: duration)
    end

    # Build schedule: [time_in_seconds, count, job_type_symbol]
    @schedule = []
    @rows.each_with_index do |row, minute_index|
      time_seconds = minute_index * 60.0

      job_columns.each_with_index do |col, i|
        count = row[col].to_i
        next if count <= 0
        @schedule << [time_seconds, count, @job_class_names[i]]
      end
    end

    @max_time = @rows.size * 60
  end

  # Build a lookup from normalized class name → {mean_ms, p90_ms}.
  #
  # Durations CSV actions look like "FetchMessageJob#perform" or
  # "DigestMailer#daily_digest". We index by the class part
  # (before #) so "FetchMessageJob" matches directly.
  #
  # @param durations [CSV::Table, nil]
  # @return [Hash{String => Hash}]
  def build_duration_lookup(durations)
    return {} unless durations

    lookup = {}
    durations.each do |row|
      action = row.fetch("action")
      class_name = action.split("#").first
      mean_ms = row.fetch("mean_ms").to_f
      p90_ms = row.fetch("p90_ms").to_f
      next if mean_ms <= 0 && p90_ms <= 0

      # Use the class name as key; if multiple methods exist for the same class,
      # the first (usually #perform) wins
      lookup[class_name] ||= {mean_ms: mean_ms, p90_ms: p90_ms}
    end
    lookup
  end

  # Look up a duration distribution from the durations CSV.
  #
  # @param column_name [String] original column name (e.g. "FetchMessageJob")
  # @return [#call] duration callable
  def find_duration(column_name)
    entry = @durations[column_name]
    return DEFAULT_DURATION unless entry

    mean_s = entry[:mean_ms] / 1000.0
    p90_s = entry[:p90_ms] / 1000.0

    # Synthesize missing values: if we have one, derive the other
    if mean_s <= 0 && p90_s <= 0
      return DEFAULT_DURATION
    elsif mean_s <= 0
      mean_s = p90_s / 1.3
    elsif p90_s <= 0
      p90_s = mean_s * 1.3
    end

    # Guard against p90 <= mean
    p90_s = mean_s * 1.3 if p90_s <= mean_s

    Skaler::Distribution.new(mean: mean_s, p90: p90_s)
  end

  def symbolize(name)
    name
      .gsub("::", "_")
      .tr("#", "_")
      .gsub(/([a-z])([A-Z])/, '\1_\2')
      .downcase
      .to_sym
  end
end
