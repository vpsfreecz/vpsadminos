require 'digest'
require 'fileutils'
require 'libosctl'
require 'osctl/exportfs/operations/base'

module OsCtl::ExportFS
  # Add export to a NFS server
  class Operations::Export::Add < Operations::Base
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include OsCtl::Lib::Utils::File

    # @param server [Server]
    # @param export [Export]
    def initialize(server, export)
      @server = server
      @export = export
      @cfg = server.open_config
    end

    def execute
      if !Dir.exist?(export.dir)
        fail "dir #{export.dir} not found"
      elsif export_exists?
        fail "export at #{export.as} already exists"
      end

      add_to_exports

      if server.running?
        enable_share
      end
    end

    protected
    attr_reader :server, :export, :cfg

    def export_exists?
      path = File.absolute_path(export.as)

      cfg.exports.each do |ex|
        return true if path == File.absolute_path(ex.as)
      end

      false
    end

    # Add the export to the database
    def add_to_exports
      cfg.exports << export
      cfg.save
    end

    # Propagate the directory from the host to the server using the shared
    # directory and then export it
    def enable_share
      hash = Digest::SHA2.hexdigest(export.dir)
      shared = File.join(server.shared_dir, hash)

      Dir.mkdir(shared)
      Sys.bind_mount(export.dir, shared)

      begin
        Operations::Server::Exec.run(server) do
          server.enter_ns

          FileUtils.mkdir_p(export.as)
          Sys.move_mount(
            File.join(RunState::CURRENT_SERVER, 'shared', hash),
            export.as
          )

          Operations::Exportfs::Generate.run(server)

          syscmd('exportfs -r')
        end

      ensure
        Sys.unmount(shared)
        Dir.rmdir(shared)
      end
    end
  end
end
