module OsCtld
  module NetInterface
    def self.register(type, klass)
      @types ||= {}
      @types[type] = klass
    end

    def self.for(type)
      @types[type]
    end
  end
end
