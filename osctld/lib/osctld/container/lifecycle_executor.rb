module OsCtld
  # Bounded per-pool lifecycle lanes.
  #
  # Leases are explicitly releasable by recovery. A worker that later returns
  # is fenced by the lifecycle effect ID and cannot commit a stale result.
  class Container::LifecycleExecutor
    class Lane
      def initialize
        @mutex = Mutex.new
        @cv = ConditionVariable.new
        @active = {}
      end

      def acquire(effect_id, limit)
        @mutex.synchronize do
          while @active.length >= limit
            return false if daemon_stopping?

            @cv.wait(@mutex)
          end
          return false if daemon_stopping?

          @active[effect_id] = true
        end
        true
      end

      def release(effect_id)
        @mutex.synchronize do
          return false unless @active.delete(effect_id)

          @cv.broadcast
          true
        end
      end

      def wake
        @mutex.synchronize { @cv.broadcast }
      end

      protected

      def daemon_stopping?
        OsCtld.const_defined?(:Daemon) && Daemon.get&.stopping?
      end
    end

    @mutex = Mutex.new
    @lanes = {}

    class << self
      def acquire(pool, type, effect_id)
        lane(pool, type).acquire(effect_id, limit(pool, type)) && effect_id
      end

      def release(pool, type, effect_id)
        lane(pool, type).release(effect_id)
      end

      def wake_all
        @mutex.synchronize { @lanes.values.dup }.each(&:wake)
      end

      protected

      def lane(pool, type)
        @mutex.synchronize do
          @lanes[[pool.name, type]] ||= Lane.new
        end
      end

      def limit(pool, type)
        case type
        when :start
          pool.parallel_start
        when :stop
          pool.parallel_stop
        else
          raise ArgumentError, "unsupported lifecycle lane #{type.inspect}"
        end
      end
    end
  end
end
