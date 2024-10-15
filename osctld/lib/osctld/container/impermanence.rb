module OsCtld
  class Container::Impermanence
    def self.load(cfg)
      new(cfg.fetch('zfs_properties', {}))
    end

    # @return [Hash<String, String>]
    attr_reader :zfs_properties

    # @param zfs_properties [Hash<String, String>]
    def initialize(zfs_properties)
      @zfs_properties = zfs_properties
    end

    def dump
      {
        'zfs_properties' => zfs_properties
      }
    end

    def dup
      ret = super
      ret.instance_variable_set('@zfs_properties', zfs_properties.dup)
      ret
    end
  end
end
