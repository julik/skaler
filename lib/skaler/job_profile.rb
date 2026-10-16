# Loads a production job profile from a CSV file and produces simulator-ready
# job types and arrival process configuration.
#
# The CSV format matches AppSignal's background action metrics export:
#
#   action,count_24h,mean_ms,p90_ms,p95_ms
#   SyncMailboxJob#perform,1210000,640.00,1150.00,1480.00
#   Search::IndexDocumentJob#perform,212000,820.00,1900.00,2600.00
#
# Each row becomes a {Skaler::JobType} with a normally-distributed duration
# derived from the mean and p90. Arrival rates are proportional to the 24h
# throughput counts.
#
# @example Load and run a simulation from production data
#   profile = Skaler::JobProfile.from_csv("examples/job_profile_24h.csv")
#
#   sim = Skaler::Simulator.new(
#     job_types: profile.job_types,
#     arrival_process: profile.arrival_process_config,
#     pid_config: { ... },
#     pool_config: { ... },
#     constraints: { ... },
#     timing: { autoscaler_interval: 60, boot_lag_seconds: 120, cooldown_seconds: 15, max_time: 7200 },
#     random_seed: 42
#   )
#   trace = sim.run
class Skaler::JobProfile
  attr_reader :job_types, :total_rate_per_minute, :type_weights

  # Parse a CSV file into a JobProfile.
  #
  # @param csv_path [String] path to CSV with columns: action, count_24h, mean_ms, p90_ms, p95_ms
  # @param hours [Numeric] how many hours the count_24h column covers (default 24)
  # @return [Skaler::JobProfile]
  def self.from_csv(csv_path, hours: 24)
    require "csv"
    rows = CSV.read(csv_path, headers: true)
    entries = rows.map do |row|
      {
        action: row.fetch("action"),
        count: row.fetch("count_24h").to_i,
        mean_ms: row.fetch("mean_ms").to_f,
        p90_ms: row.fetch("p90_ms").to_f
      }
    end
    new(entries, hours: hours)
  end

  # @param entries [Array<Hash>] parsed CSV rows with :action, :count, :mean_ms, :p90_ms
  # @param hours [Numeric] time window the counts cover
  def initialize(entries, hours: 24)
    @entries = entries
    @hours = hours
    build!
  end

  # Hash suitable for passing as the `arrival_process:` argument to {Skaler::Simulator}.
  #
  # @return [Hash] arrival process configuration with weighted type selection
  def arrival_process_config
    {
      mode: :poisson,
      rate_per_minute: @total_rate_per_minute,
      default_type: @type_weights.max_by { |_, w| w }.first,
      type_weights: @type_weights
    }
  end

  private

  def build!
    total_count = @entries.sum { |e| e[:count] }

    @job_types = {}
    @type_weights = {}
    @total_rate_per_minute = total_count.to_f / (@hours * 60)

    @entries.each do |entry|
      name = symbolize_action(entry[:action])
      mean_s = entry[:mean_ms] / 1000.0
      p90_s = entry[:p90_ms] / 1000.0

      # Guard against p90 <= mean (can happen with very low-volume jobs)
      p90_s = mean_s * 1.3 if p90_s <= mean_s

      @job_types[name] = Skaler::JobType.new(
        name: name,
        duration: Skaler::Distribution.new(mean: mean_s, p90: p90_s)
      )

      @type_weights[name] = entry[:count].to_f / total_count
    end
  end

  def symbolize_action(action)
    action
      .gsub("::", "_")
      .tr("#", "_")
      .gsub(/([a-z])([A-Z])/, '\1_\2')
      .downcase
      .to_sym
  end
end
