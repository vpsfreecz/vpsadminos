module OsCtld
  class Container::Adaptor::Base
    def self.register(name)
      Container::Adaptor.register(name, self)
    end

    include OsCtl::Lib::Utils::Log

    # @param ct [Container]
    # @param config [Hash] container config
    def initialize(ct, config)
      @ct = ct
      @config = config
    end

    # @return [Hash] adapted config
    def adapt
      config
    end

    def log_type
      ct.log_type
    end

    protected

    attr_reader :ct, :config
  end
end
