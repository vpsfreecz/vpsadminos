require 'fileutils'
require 'libosctl'
require 'osctl/exportfs/operations/base'

module OsCtl::ExportFS
  # Change the server configuration
  class Operations::Server::Configure < Operations::Base
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    # @param server [Server]
    # @param opts [Hash] options
    # @option opts [String] :address
    # @option opts [String] :netif
    # @option opts [Hash] :nfsd
    # @option opts [Integer] :mountd_port
    # @option opts [Integer] :lockd_port
    # @option opts [Integer] :statd_port
    def initialize(server, opts)
      @server = server
      @opts = opts
    end

    def execute
      server.synchronize do
        cfg = server.open_config

        %i[address netif mountd_port lockd_port statd_port].each do |v|
          cfg.send(:"#{v}=", opts[v]) unless opts[v].nil?
        end

        if opts[:nfsd]
          %i[port nproc tcp udp versions syslog].each do |v|
            cfg.nfsd.send(:"#{v}=", opts[:nfsd][v]) unless opts[:nfsd][v].nil?
          end
        end

        cfg.save
      end
    end

    protected

    attr_reader :server, :opts
  end
end
