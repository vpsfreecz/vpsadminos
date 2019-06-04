module OsCtl::Image
  class Builder
    # @return [String]
    attr_reader :base_dir

    # @return [String]
    attr_reader :name

    # @return [String]
    attr_reader :distribution

    # @return [String]
    attr_reader :version

    # @return [String]
    attr_reader :arch

    # @return [String]
    attr_reader :vendor

    # @return [String]
    attr_reader :variant

    # Attributes returned by `osctl ct show`
    # @return [Hash]
    attr_reader :attrs

    # @param dir [String]
    # @param name [String]
    def initialize(base_dir, name)
      @base_dir = base_dir
      @name = name
    end

    def load_config
      cfg = Operations::Config::ParseAttrs.run(base_dir, :builder, name)

      {
        distribution: 'DISTNAME',
        version: 'RELVER',
        arch: 'ARCH',
        vendor: 'VENDOR',
        variant: 'VARIANT',
      }.each do |attr, var|
        instance_variable_set(:"@#{attr}", cfg[var]) if cfg.has_key?(var)
      end

      @arch ||= 'x86_64'
      @vendor ||= 'vpsadminos'
      @variant ||= 'minimal'
    end

    def load_attrs(client = nil)
      @attrs = (client || OsCtldClient.new).find_container(ctid)
    end

    def ctid
      "builder-#{name}"
    end
  end
end
