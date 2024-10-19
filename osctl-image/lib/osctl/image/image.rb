module OsCtl::Image
  class Image
    # @return [String]
    attr_reader :base_dir

    # @return [String]
    attr_reader :name

    # @return [String]
    attr_reader :builder

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

    # @return [Hash<String, String>] dataset name => mountpoint
    attr_reader :datasets

    # @param base_dir [String]
    # @param name [String]
    def initialize(base_dir, name)
      @base_dir = base_dir
      @name = name
      parse_name
    end

    def load_config
      cfg = Operations::Config::ParseAttrs.run(base_dir, :image, name)

      unless cfg.has_key?('BUILDER')
        raise "builder not set for #{name}"
      end

      {
        builder: 'BUILDER',
        distribution: 'DISTNAME',
        version: 'RELVER',
        arch: 'ARCH',
        vendor: 'VENDOR',
        variant: 'VARIANT'
      }.each do |attr, var|
        instance_variable_set(:"@#{attr}", cfg[var]) if cfg.has_key?(var)
      end

      @datasets =
        if cfg.has_key?('DATASETS')
          cfg['DATASETS'].split(':').to_h { |v| v.split('=') }
        else
          {}
        end
    end

    def to_s
      name
    end

    protected

    def parse_name
      if name.index('-')
        @distribution, @version, @arch, @vendor, @variant = name.split('-')
      else
        @distribution = name
      end

      @arch ||= 'x86_64'
      @vendor ||= 'vpsadminos'
      @variant ||= 'minimal'
      nil
    end
  end
end
