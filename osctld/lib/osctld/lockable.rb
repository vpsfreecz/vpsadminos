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
    # Bound nested acquisitions without changing synchronized attribute readers.
    # The scope affects this thread only; releasing an owned lock is unconditional.
    def self.with_deadline(deadline)
      previous = Thread.current[:osctld_lock_deadline]
      Thread.current[:osctld_lock_deadline] = [previous, deadline].compact.min
      yield
    ensure
      Thread.current[:osctld_lock_deadline] = previous
    end

    def self.deadline
      Thread.current[:osctld_lock_deadline]
    end

    class Lock
      TIMEOUT = 90

      # @param object [Object]
      def initialize(object)
        @mutex = OsCtl::Lib::Mutex.new
        @in_held = []
        @in_queued = []
        @ex_queued = []
        @ex = nil
        @allow_inclusive_after_exclusive = false
        @cond_ex = ConditionVariable.new
        @cond_in = ConditionVariable.new
        @object = object
      end

      def acquire_inclusive
        return acquire_before_deadline(:inclusive) if Lockable.deadline

        t = Time.now
        is_timeout = false

        sync do
          if @ex_queued.any? && !@allow_inclusive_after_exclusive
            @in_queued << Thread.current

            # Wait for the exclusive lock to finish, if there is one
            LockRegistry.register(@object, :inclusive, :waiting)

            loop do
              now = Time.now

              if (now - t) >= TIMEOUT
                is_timeout = true
                break

              elsif @ex.nil? && (@allow_inclusive_after_exclusive || @ex_queued.empty?)
                break
              end

              @cond_in.wait(@mutex, TIMEOUT - (now - t))
            end

            if (@ex || (!@allow_inclusive_after_exclusive && @ex_queued.any?)) && is_timeout
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
          if @in_held.empty? && @ex_queued.any?
            @allow_inclusive_after_exclusive = false
            @cond_ex.signal
          end
        end
      end

      def inclusively
        return yield if @mutex.owned? && @ex == Thread.current

        held = false
        sync(acquiring: true) { held = @in_held.include?(Thread.current) }

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
        return acquire_before_deadline(:exclusive) if Lockable.deadline

        t = Time.now
        is_timeout = false

        LockRegistry.register(@object, :exclusive, :waiting)

        begin
          @mutex.lock(TIMEOUT)
        rescue OsCtl::Lib::Mutex::Timeout
          LockRegistry.register(@object, :exclusive, :timeout)
          raise OsCtld::DeadlockDetected.new(@object, :exclusive)
        end

        if @in_held.empty?
          @allow_inclusive_after_exclusive = false
          @ex = Thread.current
          LockRegistry.register(@object, :exclusive, :locked)

        elsif @in_held.include?(Thread.current)
          @mutex.unlock
          raise 'attempted to acquire exclusive lock while holding inclusive lock'

        else
          @ex_queued << Thread.current

          # Wait for all inclusive blocks to finish
          LockRegistry.register(@object, :exclusive, :waiting)

          loop do
            now = Time.now

            if (now - t) >= TIMEOUT
              is_timeout = true
              break

            elsif @in_held.empty? && @ex.nil?
              break
            end

            @cond_ex.wait(@mutex, TIMEOUT - (now - t))
          end

          if (!@in_held.empty? || @ex) && is_timeout
            LockRegistry.register(@object, :exclusive, :timeout)
            @mutex.unlock
            raise OsCtld::DeadlockDetected.new(@object, :exclusive)
          else
            @allow_inclusive_after_exclusive = false
            @ex = @ex_queued.shift
            LockRegistry.register(@object, :exclusive, :locked)
          end
        end
      end

      def release_exclusive
        unless @mutex.owned?
          raise 'expected to own the mutex, have you called acquire_exclusive first?'
        end

        # Leave exlusive block, signal waiting inclusive blocks to continue
        @ex = nil
        LockRegistry.register(@object, :exclusive, :unlocked)

        # Give the first chance to a round of inclusive locks, then exclusive
        # ones
        if @in_queued.any?
          @allow_inclusive_after_exclusive = true
          @cond_in.broadcast

        elsif @ex_queued.any?
          @allow_inclusive_after_exclusive = false
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

      # Bounded callers do not join the ordinary wait queues: a timed-out
      # waiter must not need the contended mutex again to remove its queue entry.
      def acquire_before_deadline(type)
        limit = Lockable.deadline
        LockRegistry.register(@object, type, :waiting)
        loop do
          acquired = false
          begin
            @mutex.lock(0)
            acquired = true
          rescue OsCtl::Lib::Mutex::Timeout
            # The exclusive owner still holds the mutex.
          end

          if acquired
            keep_mutex = false
            begin
              if type == :exclusive
                if @in_held.include?(Thread.current)
                  raise 'attempted to acquire exclusive lock while holding inclusive lock'
                end

                ready = @in_held.empty? && @ex.nil? && @ex_queued.empty?
                if ready
                  @allow_inclusive_after_exclusive = false
                  @ex = Thread.current
                  keep_mutex = true
                end
              else
                ready = @ex.nil? && (@allow_inclusive_after_exclusive || @ex_queued.empty?)
                @in_held << Thread.current if ready
              end
              if ready
                LockRegistry.register(@object, type, :locked)
                return
              end
            ensure
              @mutex.unlock unless keep_mutex
            end
          end

          remaining = limit - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          unless remaining > 0
            LockRegistry.register(@object, type, :timeout)
            raise OsCtld::DeadlockDetected.new(@object, type)
          end
          sleep([remaining, 0.01].min)
        end
      end

      def sync(acquiring: false)
        timeout =
          if acquiring && Lockable.deadline
            [Lockable.deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max
          else
            TIMEOUT
          end
        begin
          @mutex.lock(timeout)
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
        raise "unknown lock type '#{type}'"
      end
    end

    def unlock(type)
      case type
      when :inclusive, :ro
        @lock.release_inclusive

      when :exclusive, :rw
        @lock.release_exclusive

      else
        raise "unknown lock type '#{type}'"
      end
    end

    def inclusively(&)
      @lock.inclusively(&)
    end

    def exclusively(&)
      @lock.exclusively(&)
    end
  end
end
