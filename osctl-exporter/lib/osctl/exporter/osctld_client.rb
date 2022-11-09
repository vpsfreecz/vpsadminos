require 'libosctl'
require 'osctl'

module OsCtl::Exporter
  class OsCtldClient
    include OsCtl::Lib::Utils::Log

    attr_reader :client

    def initialize
      @client = OsCtl::Client.new
    end

    # @yieldparam client [OsCtldClient]
    def try_to_connect
      if connected?
        yield(self)
        return
      end

      begin
        client.open
      rescue SystemCallError => e
        log(:warn, "Unable to connect to osctld: #{e.message} (#{e.class})")
        @connected = false
        yield(self)
        return
      end

      @connected = true

      begin
        yield(self)
      ensure
        client.close
        @connected = false
      end
    end

    def connected?
      @connected
    end

    def ping?
      client.cmd_data!(:self_ping) == 'pong'
    end

    def status
      client.cmd_data!(:self_status)
    end

    def list_pools
      client.cmd_data!(:pool_list)
    end

    def list_containers
      client.cmd_data!(:ct_list)
    end

    def list_netifs
      client.cmd_data!(:netif_list)
    end

    def list_lxcfs_workers
      client.cmd_data!(:lxcfs_worker_list)
    end

    def health_check
      client.cmd_data!(:self_healthcheck, all: true)
    end

    def log_type
      'osctld-client'
    end
  end
end
