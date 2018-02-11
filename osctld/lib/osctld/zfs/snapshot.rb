module OsCtld
  # Class representing a single ZFS snapshot
  class Zfs::Snapshot
    # @return [Zfs::Dataset]
    attr_reader :dataset

    # @return [Hash]
    attr_reader :properties

    # @param dataset [Zfs::Dataset]
    # @param name [String]
    def initialize(dataset, name)
      @dataset = dataset
      @name = name
      @properties = {}
    end

    def name
      to_s
    end

    def snapshot
      @name
    end

    def to_s
      "#{dataset}@#{snapshot}"
    end
  end
end
