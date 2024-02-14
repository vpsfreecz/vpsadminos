require 'osctl/exportfs/operations/base'

module OsCtl::ExportFS
  # Generate exports file from the database for use with exportfs
  class Operations::Exportfs::Generate < Operations::Base
    include OsCtl::Lib::Utils::File

    # @param server [Server]
    def initialize(server)
      super()
      @server = server
    end

    def execute
      cfg = server.open_config

      regenerate_file(server.exports_file, 0o644) do |new|
        cfg.exports.each do |ex|
          new.puts("#{ex.as} #{ex.host}(#{ex.options})")
        end
      end
    end

    protected

    attr_reader :server
  end
end
