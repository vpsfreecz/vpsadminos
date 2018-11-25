require 'thread'

module OsCtld
  # This module adds support for inclusive/exclusive object locking.
  #
  # {Lockable} should be used for synchronization of osctld state. The locks
  # should be held only for a short time to read/modify the state.
  # Use {Manipulable} for long operations that require locking. Ideally, the
  # included methods should be treated as protected, i.e. should not be used
  # from the outside.
  #
  # If the thread waits for {Lockable::Lock::TIMEOUT} seconds to acquire
  # the lock, an exception is raised.
  #
  # Multiple threads can hold inclusive locks at the same time, but only one
  # thread can hold an exclusive one. When a thread has acquired an exclusive
  # lock, no other thread can get inclusive, nor exclusive lock.
  #
  # Before the locks can be used, `init_lock()` has to be called. Locks can then
  # be acquired using `lock()` and released using `unlock()`. You can also use
  # `inclusively()` and `exclusively()` to execute a block within the lock.
  #
  # {Lockable} provides helpers for synchronized alternatives to `attr_reader`,
  # `attr_writer` and `attr_accessor`:
  #
  #     attr_inclusive_reader :attr1, :attr2, ...
  #     attr_exclusive_writer :attr1, :attr2, ...
  #     attr_synchronized_accessor :attr1, :attr2, ...
  module Lockable
    class Lock
      TIMEOUT = 90

      # @param object [Object]
      def initialize(object)
        @mutex = OsCtl::Lib::Mutex.new
        @in_held = []
        @in_queued = []
        @ex_queued = []
        @ex = nil
        @cond_ex = ConditionVariable.new
        @cond_in = ConditionVariable.new
        @object = object
      end

      def acquire_inclusive
        sync do
          if @ex_queued.any?
            @in_queued << Thread.current

            # Wait for the exclusive lock to finish, if there is one
            LockRegistry.register(@object, :inclusive, :waiting)
            @cond_in.wait(@mutex, TIMEOUT)

            if @ex
              LockRegistry.register(@object, :inclusive, :timeout)
              raise OsCtld::DeadlockDetected.new(@object, :inclusive)
            else
              @in_queued.delete(Thread.current)
              @in_held << Thread.current
              LockRegistry.register(@object, :inclusive, :locked)
            end

          else
            @in_held << Thread.current
            LockRegistry.register(@object, :inclusive, :locked)
          end
        end
      end

      def release_inclusive
        sync do
          @in_held.delete(Thread.current)
          LockRegistry.register(@object, :inclusive, :unlocked)

          # Start exclusive block, if there is one waiting
          @cond_ex.signal if @in_held.empty? && @ex_queued.any?
        end
      end

      def inclusively
        return yield if @mutex.owned? && @ex == Thread.current

        held = false
        sync { held = @in_held.include?(Thread.current) }

        if held
          yield

        else
          acquire_inclusive

          begin
            yield

          ensure
            release_inclusive
          end
        end
      end

      def acquire_exclusive
        return if @mutex.owned? && @ex == Thread.current

        LockRegistry.register(@object, :exclusive, :waiting)

        begin
          @mutex.lock(TIMEOUT)
        rescue OsCtl::Lib::Mutex::Timeout
          LockRegistry.register(@object, :exclusive, :timeout)
          raise OsCtld::DeadlockDetected.new(@object, :exclusive)
        end

        if @in_held.empty?
          @ex = Thread.current
          LockRegistry.register(@object, :exclusive, :locked)

        else
          @ex_queued << Thread.current

          # Wait for all inclusive blocks to finish
          LockRegistry.register(@object, :exclusive, :waiting)
          @cond_ex.wait(@mutex, TIMEOUT)

          if !@in_held.empty?
            LockRegistry.register(@object, :exclusive, :timeout)
            raise OsCtld::DeadlockDetected.new(@object, :exclusive)
          else
            @ex = @ex_queued.shift
            LockRegistry.register(@object, :exclusive, :locked)
          end
        end
      end

      def release_exclusive
        unless @mutex.owned?
          raise "expected to own the mutex, have you called acquire_exclusive first?"
        end

        # Leave exlusive block, signal waiting inclusive blocks to continue
        @ex = nil
        LockRegistry.register(@object, :exclusive, :unlocked)

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

          begin
            yield

          ensure
            release_exclusive
          end
        end
      end

      private
      def sync
        begin
          @mutex.lock(TIMEOUT)
        rescue OsCtl::Lib::Mutex::Timeout
          raise OsCtld::DeadlockDetected.new(@object, :any)
        end

        begin
          yield
        ensure
          @mutex.unlock
        end
      end
    end

    module ClassMethods
      def attr_inclusive_reader(*attrs)
        attrs.each do |attr|
          define_method(attr) do
            inclusively { instance_variable_get("@#{attr}") }
          end
        end
      end

      def attr_exclusive_writer(*attrs)
        attrs.each do |attr|
          define_method(:"#{attr}=") do |v|
            exclusively { instance_variable_set("@#{attr}", v) }
          end
        end
      end

      def attr_synchronized_accessor(*attrs)
        attr_inclusive_reader(*attrs)
        attr_exclusive_writer(*attrs)
      end
    end

    def self.included(klass)
      klass.extend(ClassMethods)
    end

    def init_lock
      @lock = Lock.new(self)
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
