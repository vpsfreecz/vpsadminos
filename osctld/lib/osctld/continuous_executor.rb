require 'concurrent'
require 'libosctl'
require 'thread'

module OsCtld
  # Continuous execution queue
  #
  # This class handles parallel execution of queued commands with priorities.
  # Commands can be added, the queue can be cleared and the pool of workers
  # can be resized at runtime.
  class ContinuousExecutor
    # Queueable command
    class Command
      # @return [any]
      attr_accessor :id

      # @return [Integer]
      attr_accessor :priority

      # @return [Method, Proc]
      attr_accessor :callable

      # @return [Integer] internal queue order
      attr_reader :order

      # @param id [any] optional user-defined command id
      # @param payload [any] optional user-defined payload
      # @param priority [Integer] lower number means higher priority
      def initialize(id: nil, payload: nil, priority: 10, &block)
        @id = id
        @priority = priority
        @callable = block if block
        @order = 1000
      end

      def <=>(other)
        [priority, order] <=> [other.priority, other.order]
      end

      protected
      attr_writer :order

      def return_queue
        @return_queue ||= OsCtl::Lib::Queue.new
      end

      def exec
        callable.call(self)
      end

      def done(retval)
        @return_queue << retval if @return_queue
      end
    end

    include OsCtl::Lib::Utils::Log

    # @param size [Integer] initial number of workers
    def initialize(size)
      @mutex = Mutex.new
      @size = size
      @workers = []
      @front_queue = OsCtl::Lib::Queue.new
      @exec_queue = []
      @counter = Concurrent::AtomicFixnum.new(0)

      start
    end

    # Enqueue command for execution
    # @param cmd [Command, Array<Command>]
    def enqueue(cmd)
      @front_queue << cmd
    end

    # Enqueue command for execution
    # @param cmd [Command, Array<Command>]
    def <<(cmd)
      enqueue(cmd)
    end

    # Enqueue command for execution and wait until it is executed
    # @param cmd [Command]
    # @param timeout [Integer, nil] how long to wait for the command to execute
    # @return [any] return value from the executed command
    def execute(cmd, timeout: nil)
      q = cmd.send(:return_queue)
      enqueue(cmd)
      q.shift(timeout: timeout)
    end

    # Clear the execution queue
    def clear
      @front_queue << :clear
    end

    # Stop execution and wait for all workers to finish
    def stop
      @front_queue << :stop
      @main.join
    end

    # @param new_size [Integer] new number of workers
    def resize(new_size)
      @front_queue << new_size
    end

    # Return contents of the current queue
    # @return [Array<Command>]
    def queue
      sync { @exec_queue.clone }
    end

    protected
    def start
      @main = Thread.new do
        loop do
          v = @front_queue.pop

          if v.is_a?(Command)
            v.send(:'order=', @counter.increment)

            sync do
              if @workers.size < @size
                exec(v)
              else
                @exec_queue << v
                @exec_queue.sort!
              end
            end

          elsif v.is_a?(Array)
            v.each { |cmd| cmd.send(:'order=', @counter.increment) }

            sync do
              @exec_queue.concat(v)
              @exec_queue.sort!

              while @workers.size < @size && @exec_queue.any?
                exec(@exec_queue.shift)
              end
            end

          elsif v.is_a?(Thread)
            sync do
              @workers.delete(v)

              while @workers.size < @size && @exec_queue.any?
                exec(@exec_queue.shift)
              end
            end

          elsif v == :clear
            @front_queue.clear
            sync { @exec_queue.clear }

          elsif v == :stop
            sync do
              @exec_queue.clear
              @workers.each(&:join)
            end

            break

          elsif v.is_a?(Integer)
            sync do
              @size = v

              while @workers.size < @size && @exec_queue.any?
                exec(@exec_queue.shift)
              end
            end

          else
            # unknown
          end
        end
      end
    end

    def exec(cmd)
      t = Thread.new do
        begin
          ret = cmd.send(:exec)

        rescue Exception => e
          log(:warn, 'cont', "Exception raised during command execution: #{e.message}")
          puts e.backtrace.join("\n")

        ensure
          @front_queue << Thread.current
          cmd.send(:done, ret)
        end
      end

      @workers << t
    end

    def sync
      @mutex.synchronize { yield }
    end
  end
end
