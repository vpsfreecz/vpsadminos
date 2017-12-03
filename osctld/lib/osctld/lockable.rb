require 'thread'

module OsCtld
  # This module adds support for inclusive/exclusive object locking.
  #
  # Before the locks can be used, `init_lock()` has to be called. Locks can then
  # be acquired using `lock()` and released using `unlock()`. You can also use
  # `inclusively()` and `exclusively()` to execute a block within the lock.
  #
  # Multiple threads can hold inclusive locks at the same time, but only one
  # thread can hold an exclusive one. When a thread has acquired an exclusive
  # lock, no other thread can get inclusive, nor exclusive lock.
  module Lockable
    class Lock
      def initialize
        @mutex = Mutex.new
        @in_held = []
        @in_queued = []
        @ex_queued = []
        @ex = nil
        @cond_ex = ConditionVariable.new
        @cond_in = ConditionVariable.new
      end

      def acquire_inclusive
        sync do
          if @ex_queued.any?
            @in_queued << Thread.current

            # Wait for the exclusive lock to finish, if there is one
            @cond_in.wait(@mutex)

            @in_queued.delete(Thread.current)
            @in_held << Thread.current

          else
            @in_held << Thread.current
          end
        end
      end

      def release_inclusive
        sync do
          @in_held.delete(Thread.current)

          # Start exclusive block, if there is one waiting
          @cond_ex.signal if @in_held.empty? && @ex_queued.any?
        end
      end

      def inclusively
        held = false
        sync { held = @in_held.include?(Thread.current) }

        if held
          yield

        else
          acquire_inclusive
          ret = yield
          release_inclusive
          ret
        end
      end

      def acquire_exclusive
        return if @mutex.owned? && @ex == Thread.current
        @mutex.lock

        if @in_held.empty?
          @ex = Thread.current

        else
          @ex_queued << Thread.current

          # Wait for all inclusive blocks to finish
          @cond_ex.wait(@mutex)

          @ex = @ex_queued.shift
        end
      end

      def release_exclusive
        unless @mutex.owned?
          raise "expected to own the mutex, have you called acquire_exclusive first?"
        end

        # Leave exlusive block, signal waiting inclusive blocks to continue
        @ex = nil

        # Give the first chance to a round of inclusive locks, then exclusive
        # ones
        if @in_queued.any?
          @cond_in.broadcast

        elsif @ex_queued.any?
          @cond_ex.signal
        end

        @mutex.unlock
      end

      def exclusively
        if @mutex.owned? && @ex == Thread.current
          yield

        else
          acquire_exclusive
          ret = yield
          release_exclusive
          ret
        end
      end

      private
      def sync
        @mutex.synchronize { yield }
      end
    end

    def init_lock
      @lock = Lock.new
    end

    def lock(type)
      case type
      when :inclusive, :ro
        @lock.acquire_inclusive

      when :exclusive, :rw
        @lock.acquire_exclusive

      else
        fail "unknown lock type '#{type}'"
      end
    end

    def unlock(type)
      case type
      when :inclusive, :ro
        @lock.release_inclusive

      when :exclusive, :rw
        @lock.release_exclusive

      else
        fail "unknown lock type '#{type}'"
      end
    end

    def inclusively(&block)
      @lock.inclusively(&block)
    end

    def exclusively(&block)
      @lock.exclusively(&block)
    end
  end
end
