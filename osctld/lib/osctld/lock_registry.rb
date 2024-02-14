require 'libosctl'
require 'singleton'

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
    include OsCtl::Lib::Utils::Exception
    include Singleton

    class << self
      %i[setup enabled? start stop register export dump].each do |m|
        define_method(m) do |*args, &block|
          instance.send(m, *args, &block)
        end
      end
    end

    def initialize
      @enabled = nil
      @mutex = Mutex.new
      @queue = Queue.new
      @registry = []
      @last_id = Concurrent::AtomicFixnum.new(0)
    end

    def setup(enabled)
      unless @enabled.nil?
        raise 'programming error: setup can be called only once'
      end

      @enabled = enabled
      start if enabled
    end

    def enabled?
      @enabled
    end

    def start
      return unless @enabled

      @thread = Thread.new { run }
    end

    def stop
      return unless @thread

      @queue.clear
      @queue << :stop
      @thread.join
      @thread = nil
    end

    # @param object [Object]
    # @param type [:inclusive, :exclusive]
    # @param state [:waiting, :locked, :unlocked, :timeout]
    def register(object, type, state)
      return unless @enabled

      @queue << Lock.new(
        @last_id.increment,
        Time.now,
        Thread.current,
        object,
        type,
        state,
        caller[1..]
      )
    end

    def export
      return [] unless @enabled

      sync { registry.map(&:to_h) }
    end

    def dump
      unless @enabled
        log(:debug, 'locks', 'Lock registry disabled')
        return
      end

      log(:debug, 'locks', 'Dumping lock registry')

      export.each do |lock|
        log(
          :debug,
          "id=#{lock[:id]},thread=#{lock[:thread]},type=#{lock[:type]}," +
          "state=#{lock[:state]}"
        )
        log(:debug, denixstorify(lock[:backtrace]).join("\n"))
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

    def sync(&)
      if @mutex.owned?
        yield
      else
        @mutex.synchronize(&)
      end
    end
  end
end
