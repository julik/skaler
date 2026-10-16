require "minitest/autorun"
require "minitest/mock"
require "skaler"

Skaler.logger = Logger.new(IO::NULL)

module Skaler
  # Gives Minitest the `test "..." do` and `setup do` DSL the suite was written in,
  # without pulling ActiveSupport in
  class TestCase < Minitest::Test
    def self.test(name, &block)
      method_name = "test_#{name.gsub(/\s+/, "_")}"
      raise ArgumentError, "#{method_name} is already defined in #{self}" if method_defined?(method_name)
      define_method(method_name, &block)
    end

    def self.setup(&block)
      define_method(:setup) do
        super()
        instance_exec(&block)
      end
    end

    def example_path(name)
      File.expand_path("../examples/#{name}", __dir__)
    end
  end
end
