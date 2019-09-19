require 'fileutils'
require 'libosctl'
require 'osctl/exportfs/operations/base'

module OsCtl::ExportFS
  # Delete NFS server configuration
  class Operations::Server::Delete < Operations::Base
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    # @param name [String]
    def initialize(name)
      @server = Server.new(name)
    end

    def execute
      server.synchronize do
        if server.running?
          fail 'the server is running'
        end

        cleanup_shared_dir

        if Dir.exist?(server.shared_dir)
          begin
            Sys.unmount(server.shared_dir)
          rescue SystemCallError
          end

          Dir.rmdir(server.shared_dir)
        end

        # rm -rf can be run only after the shared directory has been safely removed
        FileUtils.rm_rf(server.dir, secure: true)
      end
    end

    protected
    attr_reader :server

    # Safely unmount and remove contents of the shared directory
    #
    # The shared directory can contain mounts which were left-over by some
    # unexpected failures. They have to be unmounted and safely removed with
    # rmdir. The shared dir should contain only mounts and then empty
    # directories, otherwise there's something wrong.
    def cleanup_shared_dir
      Dir.entries(server.shared_dir).each do |v|
        next if %w(. ..).include?(v)

        path = File.join(server.shared_dir, v)

        begin
          Sys.unmount(path)
        rescue SystemCallError
        end

        Dir.rmdir(path)
      end
    end
  end
end
