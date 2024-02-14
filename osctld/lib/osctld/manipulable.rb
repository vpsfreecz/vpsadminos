module OsCtld
  # Adds support for manipulation locks.
  #
  # Only one thread at a time can hold the lock. This locking mechanism should
  # be used for longer running operations on osctld resources, such as
  # containers or pools. Internal mechanisms should not depend on this lock.
  #
  # {#init_manipulable} has to be called before the lock can be used.
  #
  # Classes that include {Manipulable} can also define method
  # `manipulable_resource` which is called to give users meaningful error
  # messages. It returns an array with two elements:
  # `[resource name, resource identification]`, e.g. for containers it is
  # `["container", "<pool>:<ctid>"]`.
  #
  # Classes that are manipulating other resources (are acquiring the locks)
  # can define method `manipulation_holder` that returns a string identifying
  # the operation that is holding the lock.
  module Manipulable
    class ManipulationLock
      def initialize
        @hold = Mutex.new
        @meta = Mutex.new
      end

      def acquire(resource, by, block: false, &codeblock)
        if @hold.owned?
          # This thread already holds the lock, just call the block or return,
          # do not release the hold.
          return true unless codeblock

          codeblock.call

        elsif block
          # Get the lock, wait if necessary and release it when done
          @hold.lock
          self.holder = by

          return true unless codeblock

          run_block(&codeblock)

        elsif @hold.try_lock
          # Try to get the hold, but do not wait if it isn't available
          self.holder = by

          return true unless block_given?

          run_block(&codeblock)

        else
          raise ResourceLocked.new(resource, holder)
        end
      end

      def release
        @hold.unlock
        self.holder = nil
      end

      def locked?
        @hold.locked?
      end

      def holder
        @meta.synchronize { @holder }
      end

      protected

      def holder=(v)
        @meta.synchronize { @holder = v }
      end

      def run_block
        yield
      ensure
        @hold.unlock if @hold.owned?
        self.holder = nil
      end
    end

    def init_manipulable
      @manipulation_lock = ManipulationLock.new
    end

    # Acquire a lock
    #
    # Given block is executed with the lock held, the lock is then
    # released and the block's return value is returned.
    #
    # @param by [Object] lock holder
    # @param block [Boolean] wait for the lock or fail if it is taken
    # @yield [] block called with the lock held
    # @return [Object]
    def manipulate(by, block: false, &codeblock)
      @manipulation_lock.acquire(self, by, block:, &codeblock)
    end

    # Acquire the lock
    # @param by [Object] lock holder
    # @param block [Boolean] wait for the lock or fail if it is taken
    # @return [Boolean]
    def acquire_manipulation_lock(by, block: false)
      @manipulation_lock.acquire(self, by, block:)
    end

    # Release the lock
    def release_manipulation_lock
      @manipulation_lock.release
    end

    # Get lock holder
    def manipulated_by
      @manipulation_lock.holder
    end

    # Check if any thread holds the lock
    def is_being_manipulated?
      @manipulation_lock.locked?
    end
  end
end
