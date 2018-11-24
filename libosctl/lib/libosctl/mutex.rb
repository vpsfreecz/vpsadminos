require 'thread'

module OsCtl::Lib
  # Extended mutex with an optional timeout on lock
  class Mutex
    class Timeout < ::StandardError ; end

    def initialize
      @mutex = ::Mutex.new
      @cond = ConditionVariable.new
      @thread = nil
      @queue = 0
    end

    # Attempts to grab the lock and waits if it isn't available
    # @param timeout [Integer, nil] timeout in seconds
    # @raise [Timeout] when timeout has passed while waiting for the lock
    def lock(timeout = nil)
      t = Time.now
      is_timeout = false

      sync do
        if @thread
          @queue += 1

          loop do
            now = Time.now

            if @thread.nil?
              break

            elsif timeout && (now - t) >= timeout
              is_timeout = true
              break
            end

            @cond.wait(@mutex, timeout && (timeout - (now - t)))
          end

          @queue -= 1

          if @thread && is_timeout
            raise Timeout
          else
            @thread = Thread.current
          end

        else
          @thread = Thread.current
        end
      end

      nil
    end

    # Release the lock
    def unlock
      sync do
        if @thread == Thread.current
          @thread = nil
          @cond.signal if @queue > 0

        else
          fail 'attempted to unlock mutex owned by another thread'
        end
      end

      nil
    end

    # Execute a block with the lock
    # @param timeout [Integer, nil] timeout in seconds
    # @raise [Timeout] when timeout has passed while waiting for the lock
    def synchronize(timeout = nil)
      lock(timeout)
      yield

    ensure
      unlock if owned?
    end

    # Returns true if this lock is currently held by some thread
    def locked?
      sync { !@thread.nil? }
    end

    # Returns true if this lock is currently held by current thread
    def owned?
      sync { @thread == Thread.current }
    end

    protected
    def sync
      @mutex.synchronize { yield }
    end
  end
end
