require 'fileutils'
require 'libosctl'
require 'osctl/exportfs/operations/base'

module OsCtl::ExportFS
  # Create the server configuration
  class Operations::Server::Create < Operations::Base
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    # @param name [String]
    # @param opts [Hash] options
    # @option opts [String] :address
    # @option opts [String] :netif
    def initialize(name, opts = {})
      @server = Server.new(name)
      @opts = opts
    end

    def execute
      if Dir.exist?(server.dir)
        fail 'server already exists'
      end

      FileUtils.mkdir_p(server.dir)

      server.synchronize do
        FileUtils.mkdir_p(server.nfs_state)

        # Remount the shared dir with --make-shared
        unless Dir.exist?(server.shared_dir)
          FileUtils.mkdir_p(server.shared_dir)
          Sys.bind_mount(server.shared_dir, server.shared_dir)
          Sys.make_shared(server.shared_dir)
        end

        # Initialize the config file
        cfg = server.open_config
        cfg.address = opts[:address]
        cfg.netif = opts[:netif]
        cfg.save

        # Create an empty exports file
        File.open(server.exports_file, 'w'){}
      end
    end

    protected
    attr_reader :server, :opts

    # Forcefully create a symlink be removing existing `dst`
    def symlink!(src, dst)
      File.unlink(dst) if File.exist?(dst)
      File.symlink(src, dst)
    end
  end
end
