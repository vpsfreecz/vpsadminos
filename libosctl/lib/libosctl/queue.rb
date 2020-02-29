require 'thread'

module OsCtl::Lib
  # Replacement for stock Queue
  class Queue
    def initialize
      @mutex = ::Mutex.new
      @cond = ConditionVariable.new
      @queue = []
    end

    # Add value into queue
    def push(v)
      sync do
        @queue << v
        @cond.signal
      end
    end

    alias_method :<<, :push

    # Remove the first element from the queue and return it
    #
    # If `block` is `true`, this method will block until there is something
    # to return. If `block` is `false` and the queue is empty, `nil` is
    # returned. If `timeout` is set and passes, `nil` is returned.
    #
    # @param block [Boolean] block if the queue is empty
    # @param timeout [Integer, nil] how many seconds to wait
    def shift(block: true, timeout: nil)
      sync do
        if @queue.any?
          @queue.shift

        elsif block # Wait for something to be pushed
          loop do
            @cond.wait(@mutex, timeout)
            break if @queue.any? || timeout
          end

          @queue.shift

        else
          nil
        end
      end
    end

    alias_method :pop, :shift

    # Clear the queue
    def clear
      sync { @queue.clear }
    end

    # @return [Boolean]
    def empty?
      sync { @queue.empty? }
    end

    # @return [Boolean]
    def any?
      !empty?
    end

    def length
      sync { @queue.length }
    end

    # Return the queued values as an array
    # @return [Array]
    def to_a
      sync { @queue.clone }
    end

    protected
    def sync
      @mutex.synchronize { yield }
    end
  end
end
