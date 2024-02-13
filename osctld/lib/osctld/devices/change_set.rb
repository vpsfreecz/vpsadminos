require 'forwardable'
require 'singleton'

module OsCtld
  # Track changed devices manager to reconfigure them just once
  class Devices::ChangeSet
    include Singleton

    class << self
      extend Forwardable
      def_delegators :instance, :open, :add, :close
    end

    def initialize
      @mutex = Mutex.new
      @pools = {}
    end

    # Open new changeset on pool
    # @param pool [Pool]
    def open(pool)
      sync do
        @pools[pool.name] = {}
      end
    end

    # Add manager to the changeset
    # @param pool [Pool]
    # @param manager [Devices::Manager]
    # @param sort_key [any]
    def add(pool, manager, sort_key)
      sync do
        @pools[pool.name][sort_key] = manager
      end
    end

    # Close the changeset, applying all changes
    # @param pool [Pool]
    def close(pool)
      changes = sync { @pools.delete(pool.name) }

      changes.sort do |a, b|
        a[0] <=> b[0]
      end.each do |_, manager|
        manager.apply
      end
    end

    protected

    def sync(&)
      @mutex.synchronize(&)
    end
  end
end
