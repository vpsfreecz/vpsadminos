module OsCtld
  module Assets
    def self.register(type, klass)
      @types ||= {}
      @types[type] = klass
    end

    def self.types
      return [] unless @types

      @types.keys
    end

    def self.for_type(t)
      return unless @types

      @types[t]
    end
  end
end
