module VpsAdminOS::Converter
  class User
    def self.default
      map = ['0:666000:65536']
      new('default', 1000, map, map)
    end

    attr_accessor :name, :ugid, :uid_map, :gid_map

    def initialize(name, ugid, uid_map, gid_map)
      @name = name
      @ugid = ugid
      @uid_map = uid_map
      @gid_map = gid_map
    end

    def dump_config
      {
        'ugid' => ugid,
        'uid_map' => uid_map,
        'gid_map' => gid_map,
      }
    end
  end
end
