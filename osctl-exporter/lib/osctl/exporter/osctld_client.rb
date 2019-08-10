require 'osctl'

module OsCtl::Exporter
  class OsCtldClient
    attr_reader :client

    def initialize
      @client = OsCtl::Client.new
    end

    # @yieldparam client [OsCtldClient]
    def connect
      client.open unless connected?
      @connected = true
      yield(self)
    ensure
      client.close
      @connected = false
    end

    def list_pools
      client.cmd_data!(:pool_list)
    end

    def list_containers
      client.cmd_data!(:ct_list)
    end

    protected
    def connected?
      @connected
    end
  end
end
