module VpsAdminOS::Converter
  class Group
    def self.default
      new('default', 'default')
    end

    attr_accessor :name, :path

    def initialize(name, path)
      @name = name
      @path = path
      @cgparams = []
    end

    def dump_config
      {
        'path' => path,
        'cgparams' => [] # TODO
      }
    end
  end
end
