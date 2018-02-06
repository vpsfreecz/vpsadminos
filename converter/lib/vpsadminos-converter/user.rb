module VpsAdminOS::Converter
  class User
    def self.default
      new('default', 1000, 666000, 65536)
    end

    attr_accessor :name, :ugid, :offset, :size

    def initialize(name, ugid, offset, size)
      @name = name
      @ugid = ugid
      @offset = offset
      @size = size
    end

    def dump_config
      {
        'ugid' => ugid,
        'offset' => offset,
        'size' => size,
      }
    end
  end
end
