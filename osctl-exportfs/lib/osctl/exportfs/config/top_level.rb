require 'libosctl'

module OsCtl::ExportFS
  class Config::TopLevel
    include OsCtl::Lib::Utils::File

    # @return [Server]
    attr_reader :server

    # @return [String]
    attr_reader :path

    # @return [String]
    attr_writer :netif

    # @return [String, nil]
    attr_accessor :address

    # @return [Config::Nfsd]
    attr_reader :nfsd

    # @return [Integer, nil]
    attr_accessor :mountd_port

    # @return [Integer, nil]
    attr_accessor :lockd_port

    # @return [Integer, nil]
    attr_accessor :statd_port

    # @return [Config::Exports]
    attr_reader :exports

    # @param server [Server]
    def initialize(server)
      @server = server
      @path = server.config_file

      if File.exist?(path)
        read_config
      else
        @nfsd = Config::Nfsd.new({})
        @exports = Config::Exports.new([])
      end
    end

    # @return [String]
    def netif
      @netif || default_netif
    end

    def save
      server.synchronize do
        regenerate_file(path, 0644) do |new|
          new.write(OsCtl::Lib::ConfigFile.dump_yaml(dump))
        end
      end
    end

    protected
    def read_config
      data = server.synchronize { OsCtl::Lib::ConfigFile.load_yaml_file(path) }
      @netif = data['netif']
      @address = data['address']
      @nfsd = Config::Nfsd.new(data['nfsd'] || {})
      @mountd_port = data['mountd_port']
      @lockd_port = data['lockd_port']
      @statd_port = data['statd_port']
      @exports = Config::Exports.new(data['exports'] || [])
    end

    def default_netif
      "nfs-#{server.name}"
    end

    def dump
      {
        'address' => address,
        'netif' => @netif == default_netif ? nil : @netif,
        'nfsd' => nfsd.dump,
        'mountd_port' => mountd_port,
        'lockd_port' => lockd_port,
        'statd_port' => statd_port,
        'exports' => exports.dump,
      }
    end
  end
end
