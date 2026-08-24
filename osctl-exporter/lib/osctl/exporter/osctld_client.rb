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
      client.cmd_data!(:ct_list).map { |ct| normalize_container_state(ct) }
    end

    def list_netifs
      client.cmd_data!(:netif_list)
    end

    def cpu_scheduler_status
      client.cmd_data!(:cpu_scheduler_status)
    end

    def list_cpu_packages
      client.cmd_data!(:cpu_scheduler_package_list)
    end

    def health_check
      client.cmd_data!(:self_healthcheck, all: true)
    end

    def log_type
      'osctld-client'
    end

    protected

    def normalize_container_state(ct)
      if ct.has_key?(:runtime_state)
        ct.delete(:state)
        return ct
      end

      legacy_state = ct.delete(:state)&.to_s
      case legacy_state
      when 'staged'
        ct[:config_state] = 'staged'
        ct[:runtime_state] = 'unknown'
      when 'error'
        ct[:config_state] = 'error'
        ct[:config_state_error] = {
          source: 'legacy_state',
          message: 'legacy osctld reported an undifferentiated error state'
        }
        ct[:runtime_state] = 'unknown'
      else
        ct[:config_state] = 'ready'
        ct[:runtime_state] = legacy_state || 'unknown'
      end

      ct[:config_state_error] ||= nil
      ct[:runtime_state_error] ||= nil
      ct
    end
  end
end
