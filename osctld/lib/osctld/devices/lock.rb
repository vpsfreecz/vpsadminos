require 'singleton'
require 'thread'

module OsCtld
  # Protect manipulation of device access trees
  #
  # When managing group/container devices, it is often necessary to read or
  # modify both parent and child groups. For the lack of a better mechanism,
  # all operations on device access trees should be done only while holding
  # this per-pool lock.
  class Devices::Lock
    include Singleton

    class << self
      %i(acquire release locked? sync).each do |m|
        define_method(m) do |*args, &block|
          instance.send(m, *args, &block)
        end
      end
    end

    def initialize
      @main = Mutex.new
      @pools = {}
    end

    # @param pool [Pool]
    def acquire(pool)
      mutex(pool).lock
    end

    # @param pool [Pool]
    def release(pool)
      mutex(pool).release
    end

    # @param pool [Pool]
    def locked?(pool)
      mutex(pool).owned?
    end

    # @param pool [Pool]
    def sync(pool)
      m = mutex(pool)

      if m.owned?
        yield
      else
        m.synchronize do
          Devices::ChangeSet.open(pool)
          ret = yield
          Devices::ChangeSet.close(pool)
          ret
        end
      end
    end

    protected
    def mutex(pool)
      @main.synchronize do
        if @pools.has_key?(pool.name)
          @pools[pool.name]
        else
          @pools[pool.name] = Mutex.new
        end
      end
    end
  end
end
