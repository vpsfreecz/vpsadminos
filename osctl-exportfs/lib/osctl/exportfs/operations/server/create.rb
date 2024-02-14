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
    # @option opts [Hash] :options
    def initialize(name, opts = {})
      super()
      @server = Server.new(name)
      @opts = opts
      @sys = OsCtl::Lib::Sys.new
    end

    def execute
      if Dir.exist?(server.dir)
        raise 'server already exists'
      end

      FileUtils.mkdir_p(server.dir)

      server.synchronize do
        FileUtils.mkdir_p(server.nfs_state)

        # Remount the shared dir with --make-shared
        unless Dir.exist?(server.shared_dir)
          FileUtils.mkdir_p(server.shared_dir)
          sys.bind_mount(server.shared_dir, server.shared_dir)
          sys.make_shared(server.shared_dir)
        end

        # Initialize the config file
        Operations::Server::Configure.run(server, opts[:options])

        # Create an empty exports file
        File.new(server.exports_file, 'w').close
      end
    end

    protected

    attr_reader :server, :opts, :sys

    # Forcefully create a symlink be removing existing `dst`
    def symlink!(src, dst)
      FileUtils.rm_f(dst)
      File.symlink(src, dst)
    end
  end
end
