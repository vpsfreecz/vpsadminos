require 'fileutils'
require 'libosctl'
require 'osctl/exportfs/operations/base'

module OsCtl::ExportFS
  # Remove export from a NFS server
  class Operations::Export::Remove < Operations::Base
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include OsCtl::Lib::Utils::File

    # @param server [Server]
    # @param dir [String]
    # @param host [String]
    def initialize(server, dir, host)
      @server = server
      @db = ExportDB.new(server.exports_db)
      @export = db.lookup(dir, host)
    end

    def execute
      return if export.nil?

      remove_from_exports

      if server.running?
        disable_share
      end
    end

    protected
    attr_reader :server, :db, :export

    # Remove the export from the database
    def remove_from_exports
      db.remove(export)
      db.save
    end

    # Unexport and unmount the directory from the server namespace
    def disable_share
      Operations::Server::Exec.run(server) do
        server.enter_ns
        Operations::Exportfs::Generate.run(server)
        syscmd('exportfs -r')
        Sys.unmount(export.as)
      end
    end
  end
end
