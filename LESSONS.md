## What we learned building it

Skaler is the fourth autoscaler written for Cora's background workers. Each earlier one failed in a different way, and most of the design follows from those failures. Some of these lessons apply to autoscaling in general, not only to Skaler. [EXAMPLE_CONFIG.md](EXAMPLE_CONFIG.md) tells the Cora-specific version of the story.

### 1. Measure occupancy, not CPU

Job workers are mostly I/O-bound. A worker waiting on an HTTP call or a database query looks idle to a CPU meter while every one of its threads is busy. Scaling on CPU removes capacity exactly when the queue is about to explode.

Skaler's basic signal is **thread occupancy**, `busy / capacity`. For job workers this plays the same role that request queue time plays for web servers.

### 2. Occupancy stops at 100%, so add the backlog

Occupancy cannot go above 1.0. A saturated fleet with ten jobs waiting and a saturated fleet with ten thousand waiting give the same reading. If your setpoint is 0.85 and the fleet sits at 0.85, the controller sees no error and does nothing while the queue grows. That actually happened, with 1,220 ready jobs.

The obvious fix, `(busy + ready) / capacity`, has no upper bound. One large burst of scheduled jobs then produces a huge error, and the fleet swings between its floor and its ceiling.

Skaler's `"pressure"` mode adds a bounded backlog term instead: `min(ready / completed_since_last_tick, 3)`. This is "how many ticks it would take to drain the queue at the current throughput", and the total signal is capped at 4. It grows with the backlog, but it can't run away.

### 3. Clean the signal before you control on it

Most of the noise in a production reading comes from the _denominator_, not the numerator. Workers that are booting or shutting down make the capacity reading jump between consecutive ticks, for example from 15 to 120 for the same workload. Skaler handles this in three ways:

- **Capacity floor.** Capacity is taken as `max(capacity, busy)`. If N jobs are claimed, at least N threads exist.
- **Skip empty ticks.** A tick with zero capacity and zero busy threads (a deploy gap) is skipped without touching any state. A single 0.0 fed into the moving average would pull it down sharply, and the derivative term would amplify the drop.
- **EMA smoothing.** The smoothing factor `smoothing_alpha` trades noise rejection against response time. Find the knee of that curve in the simulator rather than guessing it.

### 4. Account for boot time

New instances take minutes to start doing work. A naive loop sees "still overloaded" on the next tick and orders more, then more again, and then has to throw most of them away. This is a classic limit cycle.

Skaler handles this in three places:

- The executor remembers each pending scale-up and refuses another one until the instances actually appear.
- If they never appear, it counts a failure. After several failures in a row it stops scaling up for a while, because "the provider isn't giving me instances" calls for a person to look, not a retry loop.
- The controller can **observe fast and act slowly**. `min_action_interval_up` keeps computing the PID on every tick, so the moving average and the integral stay current, but only lets it act once new capacity has had time to become useful.

### 5. A stateless loop must store its memory somewhere

The loop usually runs as a recurring job on whichever worker picks it up, so every tick starts with fresh objects. If the controller kept its history in memory, the integral would always be empty and the derivative would be meaningless. Your PID would quietly become a P controller with an inflated gain.

Skaler keeps the moving average, the error history and the last action time in the `MetricStore`, and loads and saves them on every step. The controller object itself holds nothing between ticks.

### 6. Ticks are irregular

A typical feedback controller - like an Airbus fly-by-wire computer - runs on a fixed frequency of 400hz, with a guaranteed clock backing it. You do not have this luxury in your web app.
 
A job scheduled every 15 seconds runs late when the system is busy, which is exactly when the autoscaler matters most. A textbook PID assumes evenly spaced samples. With irregular ones, the derivative overreacts to late ticks and the integral underweights long gaps.

Skaler's PID weights each sample by the time it actually covers, and normalizes by the _median_ observed interval. The same gains therefore work at 15s or 60s ticks. Ticks that arrive less than 2s apart, or that go backwards in time, are skipped.

### 7. Asymmetry and floors matter more than gains

Two settings mattered more than any gain tuning:

- **Scale down promptly.** If scale-up and scale-down are gated equally, frequent bursts ratchet the fleet upward. Skaler lets the two directions have different action intervals and cooldowns.
- **Keep a floor and some headroom.** If you scale down aggressively with a floor of one instance and a setpoint near 1.0, the fleet oscillates 1 → 7 → 1 through every burst. A small warm floor and a setpoint below 1.0 let ordinary bursts be absorbed by capacity you already have.

Even bigger was **capacity per instance**. Doubling threads per worker cut latency tenfold and cost by about 45% in simulation, more than any gain change. Tune your worker before you tune the loop.

### 8. The blast radius: autoscaling will find your next bottleneck

The most expensive failures came from the autoscaler working _correctly_: it scaled up to meet demand and used up a resource that other parts of the system share. Database connections, Redis clients and database CPU are each a hard wall shared with your web tier. Same for your external APIs that limit request rates, request durations and volumes. Some of these lessons were learned through incidents:

- **Every shared resource needs a constraint.** A constraint limits how many instances may be _added_. The controller takes the minimum over all constraints.
- **Per-worker estimates of connection use are only safe when the footprint is fixed.** A database pool behind a pooler has a fixed footprint, so `cap / pool_per_worker` works there. Redis clients do not: connection pools fill lazily, and in production the cost per instance varied about 4.5× between idle and burst. A constant tuned at idle let the fleet exhaust Redis, and a constant tuned on average failed again at the peak. For resources like this, **measure the usage and hand out only the remaining slack**, as `MeasuredPooledResourceConstraint` does.
- **Put the ceiling below the edge, not on it.** A budget that hands out 100% of `maxclients` guarantees that you reach it. Use a target utilization such as 0.75.
- **Assume the worst when you can't measure.** A missing or unreadable measurement should allow zero new instances. Assuming there is room is how resources get exhausted.
- **Limit the step size.** Constraints see a snapshot taken at the start of the tick. If the loop adds 15 instances in one action, they all start opening connections before the next measurement can see them. `SlewRateConstraint` caps each step.
- **Constraints only stop growth.** They do not shed instances. A fleet that is already over budget stops growing and comes down only as the PID scales down.
- **A wrong ceiling fails silently.** If your code mistakes a pooled database connection for a direct one, it applies the small direct-connection cap, and the autoscaler slowly shrinks the fleet with no error. Make detection of anything environmental explicit, and test it.

### 9. Make it observable, or a failing autoscaler looks healthy

Two incidents went unnoticed for longer than they should have because of the dashboards, not the code:

- **Chart the measurement, not your model.** A chart of `workers × pool_size` showed a comfortable Redis margin while the real client count was at the limit. Plot your estimate and the measured value side by side. When they diverge, your constants are wrong.
- **Chart the limit too.** Usage without the limit next to it gives no sense of how close you are.
- **Gauges hide spikes. Counters don't.** Many metrics backends roll a gauge up to its _last_ sample in each bucket, so an 11-minute saturation disappeared from an hourly chart. Count "ticks spent above target" as a counter and alert on that.
- **Report the numbers the decision used.** Take one reading per tick and use it for both the decision and the gauges. Otherwise the dashboard and the controller can disagree about what happened.

Skaler's `Loop` accepts any observer with `#on_step`, which gets the measurements, the full controller state (PID terms, every constraint's headroom, the reason a tick was skipped) and the result.

### 10. Simulate first, and replay real bursts

Tuning on production traffic is slow and risky. Average load also hides what matters: cron bursts and fan-out. The simulator runs the same controller and constraint classes against a deterministic, seeded model of arrivals, durations, follow-up jobs, boot lag and thread slots. It can replay per-minute enqueue counts exported from your APM, and it reports cost (instance-minutes) and queue latency for each run. Change one thing per run.

### 11. Have an off switch, and fail safe

Run the loop behind a kill switch that takes effect without a deploy. Wrap each step so that an exception means _no scaling this tick_, gets reported, and is not retried in a pile-up. An autoscaler that freezes at its current size is a small incident. One that acts on bad data is a big one.