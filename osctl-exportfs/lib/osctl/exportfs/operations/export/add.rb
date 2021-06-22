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
      @sys = OsCtl::Lib::Sys.new
    end

    def execute
      if !Dir.exist?(export.dir)
        fail "dir #{export.dir} not found"
      end

      ex = cfg.exports.find_by_as(export.as)

      if ex && ex.dir != export.dir
        fail "source directory mismatch: expected '#{ex.dir}', got '#{export.dir}'"
      elsif ex && ex.host == export.host
        fail "export of #{export.as} to #{export.host} already exists"
      end

      add_to_exports

      if server.running?
        enable_share(propagate: ex.nil?)
      end
    end

    protected
    attr_reader :server, :export, :cfg, :sys

    # Add the export to the database
    def add_to_exports
      cfg.exports << export
      cfg.save
    end

    # Propagate the directory from the host to the server using the shared
    # directory and then export it
    def enable_share(propagate: true)
      if propagate
        hash = Digest::SHA2.hexdigest(export.dir)
        shared = File.join(server.shared_dir, hash)

        Dir.mkdir(shared)
        sys.bind_mount(export.dir, shared)
      end

      begin
        Operations::Server::Exec.run(server) do
          server.enter_ns

          if propagate
            FileUtils.mkdir_p(export.as)
            sys.move_mount(
              File.join(RunState::CURRENT_SERVER, 'shared', hash),
              export.as
            )

            Operations::Exportfs::Generate.run(server)
          end

          syscmd("exportfs -i -o \"#{export.options}\" \"#{export.host}:#{export.as}\"")
        end

      ensure
        if propagate
          sys.unmount(shared)
          Dir.rmdir(shared)
        end
      end
    end
  end
end
