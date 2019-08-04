require 'osctl'

module OsCtl::Exporter
  class OsCtldClient
    attr_reader :client

    def initialize
      @client = OsCtl::Client.new
      @client.open
    end

    def list_pools
      client.cmd_data!(:pool_list)
    end

    def list_containers
      client.cmd_data!(:ct_list)
    end
  end
end
