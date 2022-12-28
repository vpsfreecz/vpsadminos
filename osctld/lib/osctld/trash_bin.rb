require 'libosctl'
require 'securerandom'

module OsCtld
  class TrashBin
    # @param pool [Pool]
    # @param dataset [OsCtl::Lib::Zfs::Dataset]
    def self.add_dataset(pool, dataset)
      pool.trash_bin.add_dataset(dataset)
    end

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    # @return [Pool]
    attr_reader :pool

    # @param pool [Pool]
    def initialize(pool)
      @pool = pool
    end

    # @param dataset [OsCtl::Lib::Zfs::Dataset]
    def add_dataset(dataset)
      zfs(:rename, nil, "#{dataset} #{trash_path(dataset)}")
    end

    def log_type
      "#{pool.name}:trash"
    end

    protected
    def trash_path(dataset)
      File.join(
        pool.trash_bin_ds,
        [
          dataset.name.split('/')[1..-1].join('-'),
          Time.now.to_i,
          SecureRandom.hex(3),
        ].join('.'),
      )
    end
  end
end
