require_relative "lib/skaler/version"

Gem::Specification.new do |spec|
  spec.name = "skaler"
  spec.version = Skaler::VERSION
  spec.authors = ["Julik Tarkhanov"]
  spec.email = ["me@julik.nl"]

  spec.summary = "PID-controlled autoscaler for background job workers, with a discrete-event simulator"
  spec.description = <<~DESC
    Skaler is a small control-loop toolkit: sensors feed a metric store, a PID controller
    turns utilization error into a scaling delta, constraints clamp it to what the
    infrastructure can take, and an actuator carries it out. The same loop runs inside
    a discrete-event simulator so gains can be tuned against recorded traffic.
  DESC
  spec.required_ruby_version = ">= 3.2"

  # Not public yet - this blocks an accidental `gem push`
  spec.metadata["allowed_push_host"] = "https://not-published.invalid"

  spec.files = Dir["lib/**/*.rb", "exe/*", "examples/*.csv", "README.md", "EXAMPLE_CONFIG.md"]
  spec.bindir = "exe"
  spec.executables = ["skaler_sim"]
  spec.require_paths = ["lib"]

  spec.add_dependency "csv"
  spec.add_dependency "logger"
end
