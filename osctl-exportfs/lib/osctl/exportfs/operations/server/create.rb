require 'fileutils'
require 'libosctl'
require 'osctl/exportfs/operations/base'

module OsCtl::ExportFS
  # Create the server configuration
  class Operations::Server::Create < Operations::Base
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    # @param name [String]
    # @param address [String, nil]
    def initialize(name, address)
      @server = Server.new(name)
      @address = address
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

        # Create directory tree for runit and link to templates from the host
        FileUtils.mkdir_p(server.runit_dir)
        %w(1 2 3).each do |v|
          symlink!(
            File.join(RunState::TPL_RUNIT_DIR, v),
            File.join(server.runit_dir, v)
          )
        end

        FileUtils.mkdir_p(server.runit_runsvdir)
        Dir.entries(RunState::TPL_RUNIT_RUNSVDIR).each do |v|
          next if %w(. ..).include?(v)

          svdir = File.join(server.runit_runsvdir, v)
          FileUtils.mkdir_p(svdir)
          symlink!(
            File.join(RunState::TPL_RUNIT_RUNSVDIR, v, 'run'),
            File.join(svdir, 'run')
          )
        end

        if address
          cfg = server.open_config
          cfg.address = address
          cfg.save
        end

        # Create an empty exports file
        File.open(server.exports_file, 'w'){}
      end
    end

    protected
    attr_reader :server, :address

    # Forcefully create a symlink be removing existing `dst`
    def symlink!(src, dst)
      File.unlink(dst) if File.exist?(dst)
      File.symlink(src, dst)
    end
  end
end
