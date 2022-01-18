require 'libosctl'

module OsCtld
  # Adapt container config to make it compatible with the current system
  module Container::Adaptor
    def self.register(name, klass)
      @adaptors ||= {}
      @adaptors[name] = klass
    end

    # @param ct [Container]
    # @param config [Hash] container config
    # @return [Hash] adapted config
    def self.adapt(ct, config)
      (@adaptors || {}).each_value do |klass|
        config = klass.new(ct, config).adapt
      end

      config
    end
  end
end
