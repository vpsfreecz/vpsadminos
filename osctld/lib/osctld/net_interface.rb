module OsCtld
  module NetInterface
    def self.register(type, klass)
      @types ||= {}
      @types[type] = klass
    end

    def self.for(type)
      @types[type]
    end

    def self.setup
      @types.each_value { |v| v.setup }
    end
  end
end
