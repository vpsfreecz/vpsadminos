require 'libosctl'
require 'thread'

module OsCtld
  # Parallel executor of queued operations
  #
  # First, add items to the internal queue using {#<<}. When done, call {#run}
  # with a block. {ExecutionPlan} will start a configured number of threads
  # and let them consume the queued items. The given block is called for every
  # executed item, but the call may be done from different threads.
  class ExecutionPlan
    include OsCtl::Lib::Utils::Log

    def initialize
      @queue = OsCtl::Lib::Queue.new
      @mutex = Mutex.new
      @cond = ConditionVariable.new
    end

    # Enqueue item, cannot be called after the execution has been started
    def <<(v)
      fail 'already in progress' if running?
      @queue << v
    end

    # Execute a block before the execution threads are started
    def on_start(&block)
      @on_start = block
    end

    # Execute a block when all threads have finished and the queue is empty
    def on_done(&block)
      @on_done = block
    end

    # Start processing of queued items
    #
    # The given block is called for every executed item. The calls can be made
    # in parallel from different threads.
    #
    # @param threads [Integer] number of threads to spawn
    # @yieldparam [v] queued item
    def run(threads, &block)
      fail 'already in progress' if running?

      @on_start && @on_start.call

      t = Thread.new do
        threads.times.map do
          Thread.new { work(block) }
        end.map(&:join)

        @on_done && @on_done.call
        @cond.broadcast
      end

      sync { @thread = t }
    end

    # Clear the queue and wait for all working threads to finish
    def stop
      @queue.clear

      sync do
        next unless @thread
        @thread.join
        @thread = nil
      end
    end

    # @return [Boolean]
    def running?
      sync { @thread && @thread.alive? }
    end

    # Wait for the execution to finish, if it is running
    def wait
      sync do
        @cond.wait(@mutex) if running?
      end
    end

    # Return the currently enqueued items in an array
    # @return [Array]
    def queue
      @queue.to_a
    end

    # Return the number of queued items
    # @return [Integer]
    def length
      @queue.length
    end

    protected
    def work(block)
      while @queue.any?
        v = @queue.shift(block: false)
        break if v.nil?

        block.call(v)
      end
    end

    def sync
      if @mutex.owned?
        yield

      else
        @mutex.synchronize { yield }
      end
    end
  end
end
