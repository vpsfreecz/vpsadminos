require 'libosctl'
require 'yaml'

module OsCtl::ExportFS
  class Config::TopLevel
    include OsCtl::Lib::Utils::File

    # @return [Server]
    attr_reader :server

    # @return [String]
    attr_reader :path

    # @param netif [String]
    attr_writer :netif

    # @param address [String]
    # @return [String, nil]
    attr_accessor :address

    # @return [Config::Exports]
    attr_reader :exports

    # @param path [Server]
    def initialize(server)
      @server = server
      @path = server.config_file

      if File.exist?(path)
        read_config
      else
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
          new.write(YAML.dump(dump))
        end
      end
    end

    protected
    def read_config
      data = server.synchronize { YAML.load_file(path) }
      @netif = data['netif']
      @address = data['address']
      @exports = Config::Exports.new(data['exports'] || [])
    end

    def default_netif
      "nfs-#{server.name}"
    end

    def dump
      {
        'address' => address,
        'netif' => @netif == default_netif ? nil : @netif,
        'exports' => exports.dump,
      }
    end
  end
end
