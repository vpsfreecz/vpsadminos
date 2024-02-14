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
    # @param as [String]
    # @param host [String]
    def initialize(server, as, host)
      super()
      @server = server
      @cfg = server.open_config
      @export = cfg.exports.lookup(as, host)
      @sys = OsCtl::Lib::Sys.new
    end

    def execute
      return if export.nil?

      remove_from_exports

      return unless server.running?

      disable_share(unmount: cfg.exports.find_by_as(export.as).nil?)
    end

    protected

    attr_reader :server, :cfg, :export, :sys

    # Remove the export from the database
    def remove_from_exports
      cfg.exports.remove(export)
      cfg.save
    end

    # Unexport and unmount the directory from the server namespace
    def disable_share(unmount: true)
      Operations::Server::Exec.run(server) do
        server.enter_ns
        Operations::Exportfs::Generate.run(server)
        syscmd("exportfs -u \"#{export.host}:#{export.as}\"")
        sys.unmount(export.as) if unmount
      end
    end
  end
end
