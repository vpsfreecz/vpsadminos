module OsCtl::ExportFS
  class Config::Nfsd
    VERSIONS = %w(2 3 4 4.0 4.1 4.2)

    # @param port [Integer]
    # @return [Integer, nil]
    attr_accessor :port

    # @param nproc [Integer]
    # @return [Integer]
    attr_accessor :nproc

    # @param tcp [Boolean]
    # @return [Boolean]
    attr_accessor :tcp

    # @param udp [Boolean]
    # @return [Boolean]
    attr_accessor :udp

    # @param versions [Array<String>]
    # @return [Array<String>]
    attr_accessor :versions

    # @param syslog [Boolean]
    # @return [Boolean]
    attr_accessor :syslog

    def initialize(cfg)
      @port = cfg['port']
      @nproc = cfg['nproc'] || 8
      @tcp = cfg['tcp'].nil? ? true : cfg['tcp']
      @udp = cfg['udp'].nil? ? false : cfg['udp']
      @versions = cfg['versions'] || ['3']
      @syslog = cfg['syslog'].nil? ? false : cfg['syslog']
    end

    def dump
      {
        'port' => port,
        'nproc' => nproc,
        'tcp' => tcp,
        'udp' => udp,
        'versions' => versions,
        'syslog' => syslog,
      }
    end

    # @return [Array<String>]
    def allowed_versions
      versions
    end

    # @return [Array<String>]
    def disallowed_versions
      VERSIONS - allowed_versions
    end
  end
end
