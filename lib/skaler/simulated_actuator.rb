# Simulated actuator that mutates a WorkerPool with virtual boot lag and cooldown.
#
# Used in the Skaler discrete-event simulator. Scale-ups are deferred via
# `@pending_boots` and materialized when `process_boots(time)` is called
# (typically at the start of each tick, before sensors read).
#
# @example
#   actuator = Skaler::SimulatedActuator.new(
#     pool: pool,
#     clock: -> { time },
#     boot_lag: 120,
#     cooldown: 15,
#     min_workers: 2,
#     max_workers: 60
#   )
#   actuator.process_boots(time)  # materialize any ready boots
#   actuator.scale(3)             # => :scaled_up (deferred by boot_lag)
class Skaler::SimulatedActuator < Skaler::Actuator
  attr_reader :pending_boots

  # @param pool [Skaler::WorkerPool] the worker pool to mutate
  # @param clock [#call] callable returning current virtual time
  # @param boot_lag [Numeric] seconds before new workers become available
  # @param cooldown [Numeric] seconds between scaling actions
  # @param min_workers [Integer] minimum worker count (floor for scale-down)
  # @param max_workers [Integer] maximum worker count (ceiling for scale-up)
  def initialize(pool:, clock:, boot_lag:, cooldown:, min_workers:, max_workers:)
    @pool = pool
    @clock = clock
    @boot_lag = boot_lag
    @cooldown = cooldown
    @min_workers = min_workers
    @max_workers = max_workers
    @pending_boots = [] # [[ready_at, count], ...]
    @last_scale_time = -Float::INFINITY
  end

  # Process any pending boot completions that are ready at the given time.
  # Call this at the start of each tick, before sensors read.
  #
  # @param time [Float] current virtual time
  def process_boots(time)
    @pending_boots.reject! do |ready_at, count|
      if time >= ready_at
        @pool.add_workers(count)
        true
      end
    end
  end

  # Execute a scaling action with cooldown and boot-lag enforcement.
  #
  # @param delta [Integer] signed delta
  # @return [Symbol] :scaled_up, :scaled_down, :noop, or :cooldown
  def scale(delta)
    return :noop if delta == 0

    now = @clock.call
    pending_count = @pending_boots.sum { |_, c| c }

    unless cooldown_elapsed?(now) && pending_count == 0
      return :cooldown
    end

    if delta > 0
      scale_up(delta, now)
    else
      scale_down(delta.abs, now)
    end
  end

  # @return [Integer] total pending boot count
  def pending_count
    @pending_boots.sum { |_, c| c }
  end

  private

  def cooldown_elapsed?(now)
    (now - @last_scale_time) >= @cooldown
  end

  def scale_up(count, now)
    max_add = @max_workers - @pool.worker_count - pending_count
    actual = [count, max_add].min
    return :noop if actual <= 0

    @pending_boots << [@clock.call + @boot_lag, actual]
    @last_scale_time = now
    :scaled_up
  end

  def scale_down(count, now)
    actual = [count, @pool.worker_count - @min_workers].min
    return :noop if actual <= 0

    @pool.remove_workers(actual)
    @last_scale_time = now
    :scaled_down
  end
end
