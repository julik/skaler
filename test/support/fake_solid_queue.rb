# In-memory stand-ins for the SolidQueue models and the bits of ActiveRecord the
# SolidQueue sensors touch. Only the query methods those sensors call are implemented,
# so a sensor reaching for something new fails loudly here instead of passing by accident.
module FakeActiveRecord
  class Relation
    include Enumerable

    class WhereChain
      def initialize(relation)
        @relation = relation
      end

      def not(conditions)
        @relation.filter_rows { |row| conditions.none? { |col, val| Array(val).include?(row.public_send(col)) } }
      end
    end

    def initialize(rows)
      @rows = rows
    end

    def where(conditions = nil, *binds)
      return WhereChain.new(self) if conditions.nil?

      case conditions
      when Hash
        filter_rows { |row| conditions.all? { |col, val| Array(val).include?(row.public_send(col)) } }
      when /\A(\w+) > \?\z/
        col = $1
        filter_rows { |row| (v = row.public_send(col)) && v > binds.first }
      else
        raise ArgumentError, "FakeActiveRecord does not understand #{conditions.inspect}"
      end
    end

    def order(spec)
      col, dir = spec.first
      sorted = @rows.sort_by { |row| row.public_send(col) }
      Relation.new((dir == :desc) ? sorted.reverse : sorted)
    end

    def filter_rows(&block)
      Relation.new(@rows.select(&block))
    end

    def all = self

    def each(&) = @rows.each(&)

    def count = @rows.size

    def first = @rows.first

    def pluck(col) = @rows.map { |row| row.public_send(col) }
  end

  class Model
    class << self
      def rows
        @rows ||= []
      end

      def create!(**attrs)
        rows << self::Row.new(**attrs)
      end

      def delete_all
        rows.clear
      end

      def all = Relation.new(rows)

      def where(...) = all.where(...)

      def count = all.count

      def pluck(col) = all.pluck(col)
    end
  end

  DbConfig = Struct.new(:host, :configuration_hash)
  ConnectionPool = Struct.new(:size)
end

module SolidQueue
  class Process < FakeActiveRecord::Model
    Row = Struct.new(:kind, :last_heartbeat_at, :metadata)
  end

  class ClaimedExecution < FakeActiveRecord::Model
    Row = Struct.new(:job_id)
  end

  class Job < FakeActiveRecord::Model
    Row = Struct.new(:finished_at)
  end

  class Pause < FakeActiveRecord::Model
    Row = Struct.new(:queue_name)
  end

  class ReadyExecution < FakeActiveRecord::Model
    Row = Struct.new(:queue_name)
  end

  def self.reset_fakes!
    [Process, ClaimedExecution, Job, Pause, ReadyExecution].each(&:delete_all)
  end
end

module ActiveRecord
  class Base
    class << self
      def connection_db_config
        FakeActiveRecord::DbConfig.new(host: "localhost", configuration_hash: {port: 5432})
      end

      def connection_pool
        FakeActiveRecord::ConnectionPool.new(7)
      end
    end
  end
end
