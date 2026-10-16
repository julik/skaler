# Skaler

Skaler is a toolkit for building a feedback-controlled autoscaler for background job workers. It has three parts:

- A PID control loop.
- A set of constraints that stop it from scaling past what your infrastructure can take.
- A discrete-event simulator, so you can tune it against your own traffic before production sees it.

It ships sensors for Solid Queue and an actuator for Render. Everything else is plain Ruby, and every piece can be swapped out.

> [!TIP]
> This gem was created for [Cora,](https://cora.computer/)
> your personal e-mail assistant.
> Send them some love for allowing me to share it.

## See it work

The simulator needs nothing but Ruby. Clone the repo and replay four hours of the bundled sample traffic through a concrete configuration. These are Cora's production settings:

```sh
git clone https://github.com/julik/skaler.git && cd skaler
bundle install

bundle exec exe/skaler_sim \
  --ingress-csv examples/enqueues_per_minute.csv \
  --durations examples/job_durations.csv \
  --kp 1.0 --ki 0.01 --kd 2.0 --setpoint 0.8 --deadband 0.2 \
  --alpha 0.45 --mode pressure \
  --workers 2 --max-workers 60 --threads 12 \
  --interval 15s --boot-lag 3m --cooldown 45s
```

It finishes in well under a minute and prints a summary:

```
Peak instances: 21  |  Total completed: 837343  |  Cost: 1776.5 instance-minutes
Queue latency:  avg p50=13.338s  avg p95=16.631s  peak max=91.819s
SVG written to tmp/skaler_trace.svg
```

On macOS the chart opens in Quick Look. Elsewhere, open `tmp/skaler_trace.svg` in a browser. Per-tick numbers are in `tmp/skaler_trace.csv`.

![Simulated trace: instances, signal, arrivals, backlog, PID terms and queue latency over four hours](docs/example_trace.svg)

Reading it from the top:

- **Instances.** Green dashed lines mark scale-ups and red dashed lines mark scale-downs. The fleet climbs after every 5-minute sync burst and shrinks again before the next one arrives. The big step around the 2-hour mark is the digest spike.
- **Utilization.** The raw signal is orange, the smoothed one is blue, and the setpoint is the dashed red line.
- **Arrivals per tick** and **Ready Queue Depth** show the demand and the backlog it leaves behind.
- **PID Output** shows the P, I and D terms separately, so you can see which one is driving each decision.
- **Queue Latency** is on a log scale. This is what your users actually feel.

Now change one thing and run it again. Adding `--workers 6` keeps a warmer floor: cost goes up about 10%, and average p50 latency drops from 13.3s to 9.5s. Every flag is listed under [The simulator](#the-simulator), and you can replay your own traffic as described in [Feeding it your own traffic](#feeding-it-your-own-traffic).

## Skaler is a kit, not a product

You will not find `Skaler.configure { max_instances 20 }` here, and that is deliberate.

An autoscaler that works is dangerous. Each instance it adds opens database connections, Redis clients and API sessions, and runs queries against the same database your web traffic reads from. Which of these runs out first, and at what fleet size, depends on _your_ setup: your connection pooler, your Redis plan, your thread count, and whatever else shares those resources. Generic defaults would be tuned for somebody else's bottleneck, and the gem cannot know yours.

So Skaler gives you small parts with narrow jobs: sensors, a store, a controller, constraints and an actuator. You wire them together yourself, in a few dozen lines of your own code. That wiring is where you write down what "safe" means for your system: which resources the loop must never exhaust, how fast it may grow, what it does when a reading fails, and how you will see it misbehave.

Expect to spend more time on the constraints and the dashboards than on the PID gains. For a complete worked example, with the reasoning and the incidents behind each choice, see [EXAMPLE_CONFIG.md](EXAMPLE_CONFIG.md). Read [LESSONS.md](LESSONS.md) for some hard-earned knowledge.

## Installation

```ruby
# Gemfile
gem "skaler", git: "https://github.com/julik/skaler.git"
```

```ruby
require "skaler"               # controller, constraints, stores, Render actuator, simulator
require "skaler/solid_queue"   # Solid Queue / ActiveRecord sensors - needs a booted Rails app
```

The only runtime dependencies are `csv` and `logger`. Redis and Render clients are duck-typed, so you pass in the clients you already have.

## How the loop fits together

Each tick, the loop measures the system, compares a process variable with a setpoint, and turns the difference into an instance delta. The delta is limited by constraints, and the actuator carries it out.

```mermaid
flowchart LR
    subgraph Plant["The system being scaled"]
        Q[("Job queue")]
        W["Worker instances<br/>N x threads"]
        Q --> W
    end

    subgraph Loop["Skaler::Loop (one step)"]
        S["Sensors<br/>take_measurement"]
        M[("MetricStore<br/>time series +<br/>controller state")]
        C["Controller<br/>EMA, PID, clamps,<br/>constraints"]
        A["Actuator<br/>cooldown, min/max,<br/>boot-lag tracking"]
        O["Observer<br/>trace / gauges / logs"]
        S -->|measurements hash| M
        M -->|latest + saved state| C
        C -->|signed delta| A
        C -.->|last_state| O
        A -.->|result symbol| O
    end

    W -->|busy threads, capacity,<br/>ready jobs| S
    A -->|scale to N| W
    K["Constraints<br/>DB / Redis / max / slew"] -->|max_additional| C
```

| Role | Interface | Shipped implementations |
|------|-----------|-------------------------|
| **Sensor** | `#take_measurement -> Numeric` | `Sensor.from { ... }`, `RedisConnectionsSensor`, `RedisConnectionCapSensor`, `RenderInstancesSensor`, and the Solid Queue sensors below |
| **MetricStore** | `now`, `record`, `recall(over_last:)`, `ready?(min_duration:)`, `latest`, `save_controller_state`, `load_controller_state` | `MemoryMetricStore` (injectable clock), `RedisMetricStore` (sorted set, Redis `TIME` as the clock, so all processes agree) |
| **Controller** | `#step(store) -> Integer`, `#last_state` | `Controller`, wrapping a pure `PidController` |
| **Constraint** | `#evaluate(active_workers:) -> {max_additional:, ...}` | `PooledResourceConstraint`, `MeasuredPooledResourceConstraint`, `MaxInstancesConstraint`, `SlewRateConstraint` |
| **Actuator** | `#scale(delta) -> :scaled_up / :scaled_down / :noop / :cooldown` | `RenderActuator` (via `ScaleExecutor`), `SimulatedActuator` |
| **Observer** | `#on_step(time:, measurements:, controller_state:, delta:, result:)` | `Trace`, or anything you write |

You can replace any row. Examples: a sensor that reads Sidekiq's API, an actuator that patches a Kubernetes Deployment, a store backed by Postgres, a constraint that reads `pg_stat_activity`.

### Solid Queue sensors

`require "skaler/solid_queue"`:

| Sensor | Reads |
|--------|-------|
| `ActiveWorkersSensor` | `SolidQueue::Process` rows of kind `Worker` that sent a heartbeat in the last 5 minutes |
| `ThreadsPerWorkerSensor` | `thread_pool_size` from the newest live worker's metadata. Falls back to 5 |
| `CapacitySensor` | active workers × threads per worker |
| `ClaimedJobsSensor` | `SolidQueue::ClaimedExecution.count`: jobs currently running |
| `ReadyJobsSensor` | ready executions on the queues the live workers serve, minus paused queues |
| `CompletedJobsSensor` | jobs with `finished_at` after a cutoff, which you supply as a callable |
| `PgConnectionsSensor` | active workers × the ActiveRecord pool size |
| `PgConnectionCapSensor` | the Postgres connection cap: high when a pooler is detected (hostname contains `bouncer`, or port 6432), 350 otherwise |

### Sensor names are the contract

A sensor doesn't know its own name. You give it one when you build the sensors hash. The controller reads these keys from `store.latest`:

| Key | Meaning | Falls back to |
|-----|---------|---------------|
| `:active_workers` | instance count, passed to constraints | `0` |
| `:capacity` | total thread slots | `0` |
| `:busy_threads` | occupied slots | `:claimed_jobs` |
| `:ready_jobs` | backlog (pressure mode only) | `:ready_queue_depth` |
| `:completed_jobs` | throughput since the last tick (pressure mode only) | `:completed_since_last` |

You can add other keys. They are stored and passed to the observer, which makes them useful for dashboards.

### One step

```mermaid
sequenceDiagram
    autonumber
    participant L as Loop
    participant S as Sensors
    participant M as MetricStore
    participant C as Controller
    participant K as Constraints
    participant A as Actuator
    participant O as Observer

    L->>S: take_measurement (each sensor once)
    S-->>L: {active_workers:, capacity:, ...}
    L->>M: record(measurements)
    L->>C: step(store)
    C->>M: ready?, latest, load_controller_state
    C->>K: evaluate(active_workers:)
    K-->>C: max_additional (min over all constraints)
    C->>C: EMA → error → PID → clamps → deadband → hold
    C->>M: save_controller_state
    C-->>L: delta
    alt delta != 0
        L->>A: scale(delta)
        A-->>L: :scaled_up / :scaled_down / :noop / :cooldown
    end
    L->>O: on_step(time:, measurements:, controller_state:, delta:, result:)
```

### Inside the controller

```mermaid
flowchart TD
    start(["step(store)"]) --> warm{"store.ready?<br/>(warm_up_duration)"}
    warm -- no --> z1["delta = 0<br/>last_state: warm_up"]
    warm -- yes --> latest{"latest<br/>measurement?"}
    latest -- no --> z2["delta = 0<br/>last_state: no_data"]
    latest -- yes --> cons["Evaluate constraints<br/>max_additional = min(...)"]
    cons --> zero{"capacity ≤ 0 and<br/>busy ≤ 0?"}
    zero -- yes --> z3["delta = 0, state untouched"]
    zero -- no --> util["raw = busy / max(capacity, busy)<br/>pressure: + min(ready / completed, 3), cap 4"]
    util --> ema["smoothed = α·raw + (1-α)·smoothed<br/>error = smoothed - setpoint"]
    ema --> dt{"dt since last<br/>sample"}
    dt -- "≤ 0" --> z4["skip: clock went backwards"]
    dt -- "< 2s" --> z5["skip, keep EMA"]
    dt -- ok --> pid["PID over last 10 samples<br/>nominal_dt = median tick interval"]
    pid --> clamp["Clamp D to ±10, output to ±15"]
    clamp --> db{"|output| < deadband?"}
    db -- yes --> z6["delta = 0"]
    db -- no --> sign["up: min(ceil(output), max_additional)<br/>down: -ceil(|output|)"]
    sign --> hold{"acted within<br/>min_action_interval_up/down?"}
    hold -- yes --> z7["delta = 0, held: true<br/>PID state still advances"]
    hold -- no --> out(["delta"])
```

The deadband matters more than it looks. Widening it from 0.1 to 0.2 cut scaling events from 325 to 42 over a simulated 12 hours, with almost no change in latency.

### Constraints

Each constraint receives the current worker count and returns `{max_additional: Integer, **details}`. The detail keys, such as `headroom_pg`, `headroom_redis` and `redis_utilization`, end up in `last_state` for your dashboards.

| Constraint | Model | Use for |
|------------|-------|---------|
| `PooledResourceConstraint.new(cap:, pool_per_worker:, name:)` | open loop: `cap / pool_per_worker - workers` | resources where each worker takes a fixed, known share, such as a database pool behind a pooler |
| `MeasuredPooledResourceConstraint.new(usage:, cap:, pool_per_worker:, target_utilization:, name:)` | closed loop: `(cap × target - usage) / pool_per_worker`. Allows nothing if a reading is missing | resources whose per-worker footprint grows with load, such as Redis clients |
| `MaxInstancesConstraint.new(max:)` | `max - workers` | a hard ceiling on fleet size, usually set by budget |
| `SlewRateConstraint.new(max_step:)` | constant `max_step` | limiting overshoot between two measurements |

`cap` and `usage` can be integers or callables. Callables are resolved on every evaluation. To add your own, subclass `Skaler::Constraint` and implement `#evaluate(active_workers:)`.

### Actuators

`RenderActuator` turns a delta into a target instance count. It clamps the target to `[min_instances, max_instances]`, applies separate up and down cooldowns, and hands the target to `ScaleExecutor`. The executor keeps its own state in Redis:

```mermaid
stateDiagram-v2
    [*] --> Idle
    Idle --> Pending: scale_to(target > current)<br/>records pending_target
    Idle --> Idle: scale_to(target ≤ current)
    Pending --> Idle: record_tick, active workers ≥ target<br/>reset failures
    Pending --> Idle: record_tick, boot_lag_timeout passed<br/>failures += 1
    Idle --> Backoff: failures ≥ max_consecutive_failures
    Backoff --> Idle: backoff_seconds elapsed
    note right of Pending
        can_scale_up? is false while Pending or in Backoff.
        Scale-downs are always allowed.
    end note
```

Call `executor.record_tick(active_sq_workers:)` before each step, so that arrivals and timeouts are detected.

The Render client is duck-typed. It needs to respond to:

```ruby
client.services                                        # => [#<obj service=#<obj id="srv-..." name="...">>, ...]
client.instance_count(service_id: "srv-...")           # => Integer
client.scale_service(service_id: "srv-...", instance_count: 6)
```

Pass `on_scale: ->(by_n:, direction:, timestamp:) { ... }` to `ScaleExecutor` to emit metrics or notifications for each scale command.

For any other platform, write an actuator: a class with `#scale(delta)` that returns one of the four result symbols. Use `ScaleExecutor` as a template for tracking boot lag.

## Building your own setup

Before you write the wiring, answer these questions. Each answer becomes a line of configuration.

1. **What is the process variable, and what setpoint gives you headroom?** Use occupancy for steady load, or pressure when backlog builds up while the fleet is saturated. Use a setpoint below 1.0.
2. **What do workers share, and what is each one's footprint?** Fixed footprint: use `PooledResourceConstraint`. Footprint that grows with load: measure it and use `MeasuredPooledResourceConstraint` with a target below 1.0.
3. **How fast may the fleet grow?** Set a slew limit, an up-interval at least as long as boot time, and a cooldown.
4. **What are the floor and the ceiling?** The floor is the capacity you keep warm. The ceiling is your budget, or the point where your shared resources run out.
5. **What happens when a reading fails?** The answer should be "nothing scales this tick".
6. **How do you stop it?** You need a kill switch that works without a deploy.
7. **How will you know it is wrong?** Plan the gauges for every reading the decision used, the limit next to each usage figure, a counter of ticks spent near a limit, and an alert on that counter.

A minimal Solid Queue + Render loop, run from a recurring job:

```ruby
require "skaler"
require "skaler/solid_queue"

Skaler.logger = Rails.logger

def autoscale_tick(redis)
  executor = Skaler::ScaleExecutor.new(render_client: my_render_client, redis: redis)
  service_id = executor.find_service_id(service_name: "my-worker") or return
  executor.record_tick(active_sq_workers: Skaler::ActiveWorkersSensor.new.take_measurement)

  clients = redis.info("clients")

  Skaler::Loop.new(
    sensors: {
      active_workers: Skaler::ActiveWorkersSensor.new,
      capacity: Skaler::CapacitySensor.new,
      claimed_jobs: Skaler::ClaimedJobsSensor.new,
      ready_jobs: Skaler::ReadyJobsSensor.new,
      completed_jobs: Skaler::CompletedJobsSensor.new(since: -> { Time.now - 15 })
    },
    store: Skaler::RedisMetricStore.new(redis: redis, key_prefix: "skaler:metrics"),
    controller: Skaler::Controller.new(
      pid: Skaler::PidController.new(kp: 1.0, ki: 0.01, kd: 2.0, deadband: 0.2),
      setpoint: 0.8,
      smoothing_alpha: 0.45,
      metric_mode: "pressure",
      min_action_interval_up: 60,   # roughly your boot time
      min_action_interval_down: 0,
      constraints: [
        Skaler::PooledResourceConstraint.new(
          cap: 500, pool_per_worker: ActiveRecord::Base.connection_pool.size, name: :pg
        ),
        Skaler::MeasuredPooledResourceConstraint.new(
          usage: clients["connected_clients"].to_i, cap: clients["maxclients"].to_i,
          pool_per_worker: 20, target_utilization: 0.75, name: :redis
        ),
        Skaler::SlewRateConstraint.new(max_step: 4),
        Skaler::MaxInstancesConstraint.new(max: 20)
      ]
    ),
    actuator: Skaler::RenderActuator.new(
      executor: executor, service_id: service_id,
      min_instances: 2, max_instances: 20, cooldown_up: 45, cooldown_down: 45
    ),
    observer: MyGaugeReporter.new
  ).step
rescue => e
  report_error(e)
  nil
end
```

The numbers above are placeholders. Replace each one with a value you can justify for your own system, then check it in the simulator. [EXAMPLE_CONFIG.md](EXAMPLE_CONFIG.md) walks through one production setup and explains every value in it.

## The simulator

`Skaler::Simulator` runs the same `Loop`, `Controller` and constraint classes against a simulated job system. Several hours of traffic replay in about a second.

```mermaid
flowchart TD
    subgraph Inputs
        AP["ArrivalProcess<br/>:poisson / :compound_poisson / :scheduled"]
        JT["JobTypes<br/>duration distribution + spawn_rules"]
    end
    AP -->|"pre-seeds :job_arrived events"| EQ[("EventQueue<br/>min-heap on (time, seq)")]
    EQ -->|pop next event| D{"dispatch"}
    D -->|":job_arrived"| TS["try_start_job<br/>acquire slot or enqueue"]
    D -->|":job_completed"| JC["release slot<br/>roll cascades<br/>drain ready queue"]
    D -->|":autoscaler_tick"| AT["process_boots<br/>drain ready queue<br/>Loop.step<br/>record latency, cost"]
    TS -->|"push completion at t+duration"| EQ
    JC -->|"children → try_start_job"| TS
    AT -->|"push next tick at t+interval"| EQ
    AT --> SA["SimulatedActuator"]
    SA -->|"boot after boot_lag"| WP["WorkerPool<br/>workers × threads"]
    TS <--> WP
    JC <--> WP
    AT --> TR["Trace snapshots"] --> OUT["SvgChart / CSV"]
```

All randomness comes from one seeded `Random`, so a run is deterministic for a given `random_seed`.

### Running it

```sh
bundle exec exe/skaler_sim --help
bundle exec exe/skaler_sim --max-time 2h --rate 730 --kp 1.0 --kd 2.0
```

The run prints peak instances, completed jobs, cost in instance-minutes and queue latency to stderr. It writes `tmp/skaler_trace.svg` and `tmp/skaler_trace.csv`, and opens the SVG in Quick Look on macOS unless you pass `--no-open`. The chart has six stacked panels: instances with scale markers, raw and smoothed signal against the setpoint, arrivals per tick, ready-queue depth, the P/I/D terms, and queue latency on a log scale.

Every flag can also be set as an upper-case environment variable, such as `KP=1.2 MAX_TIME=8h`. Flags take precedence.

| Group | Flags |
|-------|-------|
| Load | `--rate N` (arrivals/min, Poisson), `--cascade F` (chance that a job spawns a follow-up), `--profile CSV`, `--profile-hours N`, `--ingress-csv CSV`, `--durations CSV`, `--burst-ratio F`, `--seed N`, `--max-time 8h` |
| PID | `--kp`, `--ki`, `--kd`, `--setpoint`, `--deadband` |
| Fleet | `--workers N` (initial and minimum), `--max-workers N`, `--threads N` |
| Timing | `--interval 60s`, `--boot-lag 3m`, `--cooldown 45s` |
| Signal | `--mode utilization\|pressure`, `--alpha F` |
| Output | `--output PATH`, `--csv PATH`, `--no-csv`, `--no-open` |

### Sample data

`examples/` contains made-up traffic for a fictional mail-sync app. It is shaped like real production data, so you can try the simulator before you export your own:

| File | Shape |
|------|-------|
| `job_profile_24h.csv` | 12 job classes, about 3M jobs a day. Mostly sub-second jobs, plus a slow digest job and a very slow export |
| `enqueues_per_minute.csv` | 4 hours, one row per minute: a mailbox-sync cron burst every 5 minutes, occasional webhook storms, a slow morning ramp, and a 12-minute digest spike at 08:00 |
| `job_durations.csv` | mean and p90 for the job classes in the ingress file |

```sh
# Steady, averaged load
bundle exec exe/skaler_sim --profile examples/job_profile_24h.csv --max-time 2h

# Bursty replay, which is where the tuning matters
bundle exec exe/skaler_sim --ingress-csv examples/enqueues_per_minute.csv --durations examples/job_durations.csv
```

### Feeding it your own traffic

There are three load models, from least to most realistic:

1. **Synthetic Poisson** (default): `process_email` jobs arrive at `--rate`, and each one spawns a `summarize` job with probability `--cascade`.
2. **24h profile** (`--profile`): an APM background-action export. Each row becomes a job type with a normal duration distribution fitted from mean and p90. Arrival weights are proportional to `count_24h`.
   ```csv
   action,count_24h,mean_ms,p90_ms,p95_ms
   SyncMailboxJob#perform,1210000,640.00,1150.00,1480.00
   FetchMessageJob#perform,540000,410.00,1290.00,1650.00
   ```
3. **Per-minute ingress replay** (`--ingress-csv`, optionally `--durations`): one row per minute and one column per job class. A share of each minute's arrivals (`--burst-ratio`) lands in a burst of about 3 seconds, and the rest are spread across the minute. This reproduces the cron and pub/sub spikes that averaged profiles hide.
   ```csv
   timestamp,SyncMailboxJob,ProcessWebhookJob,FetchMessageJob
   2026-10-12T06:00:00Z,3341,620,1218
   2026-10-12T06:01:00Z,401,551,143
   ```

### From Ruby

```ruby
sim = Skaler::Simulator.new(
  job_types: {
    work: Skaler::JobType.new(name: :work, duration: Skaler::Distribution.new(mean: 1.2, p90: 3.5))
  },
  arrival_process: {mode: :poisson, rate_per_minute: 900, default_type: :work},
  pid_config: {kp: 1.0, ki: 0.01, kd: 2.0, setpoint: 0.8, deadband: 0.2},
  pool_config: {initial_workers: 2, threads_per_worker: 12, min_workers: 2, max_workers: 60},
  constraints: {pg_max: 2000, redis_max: 5000, pg_pool_size: 14, redis_pool_per_worker: 12},
  timing: {autoscaler_interval: 15, boot_lag_seconds: 180, cooldown_seconds: 45, max_time: 4 * 3600},
  smoothing_alpha: 0.45,
  metric_mode: "pressure",
  random_seed: 7
)
trace = sim.run
File.write("trace.svg", Skaler::SvgChart.render(trace, setpoint: 0.8))
```

`Skaler::Builder.simulation(...)` assembles the same loop around a pool and clock you provide, if you want to drive ticks yourself.

### What the simulator leaves out

The simulator models the controller and the open-loop constraints exactly. It does _not_ model:

- your provider's API latency
- separate up/down cooldowns and `min_action_interval_*`
- measured, closed-loop resource usage
- the effect of your fleet on the database it shares with everything else

Use it to compare settings with each other, not to predict production instance counts.

## Development

```sh
bundle install
bundle exec rake test     # minitest, no database or Redis needed
bundle exec standardrb
```

The tests run without Rails. They use a `test "..." do` / `setup do` shim over `Minitest::Test` (in `test/test_helper.rb`) and small in-memory stand-ins for the Solid Queue models, ActiveRecord's DB config and Redis (in `test/support/`). The fakes implement only the query methods the sensors actually call. If a sensor starts using a new one, its test fails right away.
