module OsCtl::ExportFS
  module Config
    # @param server [Server]
    # @return [Config::TopLevel]
    def self.open(server)
      TopLevel.new(server)
    end
  end
end
