require 'libosctl'
require 'singleton'
require 'thread'

module OsCtld
  # Global registry of all inclusive/exclusive logs for debugging purposes
  #
  # All inclusive/exclusive locks that are attempted and held are registered
  # in this class. The idea is that when a deadlock occurs, you can inspect
  # the data available within this class to see what threads have acquired
  # what locks on what objects and get backtraces.
  class LockRegistry
    Lock = Struct.new(:id, :time, :thread, :object, :type, :state, :backtrace) do
      def ==(other)
        thread == other.thread && object == other.object && type == other.type
      end
    end

    include OsCtl::Lib::Utils::Log
    include Singleton

    class << self
      %i(start stop register export dump).each do |m|
        define_method(m) do |*args, &block|
          instance.send(m, *args, &block)
        end
      end
    end

    def initialize
      @mutex = Mutex.new
      @queue = Queue.new
      @registry = []
      @last_id = Concurrent::AtomicFixnum.new(0)
    end

    def start
      @thread = Thread.new { run }
    end

    def stop
      if @thread
        @queue.clear
        @queue << :stop
        @thread.join
        @thread = nil
      end
    end

    # @param object [Object]
    # @param type [:inclusive, :exclusive]
    # @param state [:waiting, :locked, :unlocked, :timeout]
    def register(object, type, state)
      @queue << Lock.new(
        @last_id.increment,
        Time.now,
        Thread.current,
        object,
        type,
        state,
        caller[1..-1]
      )
    end

    def export
      sync { registry.map(&:to_h) }
    end

    def dump
      log(:debug, 'locks', 'Dumping lock registry')

      export.each do |lock|
        log(
          :debug,
          "id=#{lock[:id]},thread=#{lock[:thread]},type=#{lock[:type]},"+
          "state=#{lock[:state]}"
        )
        log(:debug, lock[:backtrace].join("\n"))
      end

      log(:debug, 'locks', 'End of dump')
    end

    def log_type
      'locks'
    end

    protected
    attr_reader :registry

    def run
      loop do
        v = @queue.pop

        if v.is_a?(Lock)
          do_register(v)

        elsif v == :stop
          break
        end
      end
    end

    def do_register(lock)
      sync do
        case lock.state
        when :waiting
          if lock.type != :exclusive || !registry.detect { |v| v == lock && v.state == :waiting }
            registry << lock
          end

        when :locked
          waiting = registry.detect { |v| v == lock && v.state == :waiting }

          if waiting
            waiting.state = :locked
            waiting.backtrace = lock.backtrace
          else
            registry << lock
          end

        when :unlocked, :timeout
          registry.delete_if { |v| v == lock }

        else
          registry << lock
        end
      end
    end

    def sync(&block)
      if @mutex.owned?
        yield
      else
        @mutex.synchronize(&block)
      end
    end
  end
end
