require 'osctl/exporter/collectors/base'

module OsCtl::Exporter
  class Collectors::OsCtld < Collectors::Base
    def setup
      @osctld_up = registry.gauge(
        :osctld_up,
        docstring: '1 if osctld is up and running, 0 if it is down'
      )

      @osctld_responsive = registry.gauge(
        :osctld_responsive,
        docstring: '1 if osctld is responding, 0 if not'
      )

      @osctld_initialized = registry.gauge(
        :osctld_initialized,
        docstring: '1 if osctld is initialized, 0 if not'
      )

      @osctld_start_time = registry.gauge(
        :osctld_start_time_seconds,
        docstring: 'Unix timestamp when osctld was started'
      )
    end

    def collect(client)
      @osctld_up.set(client.connected? ? 1 : 0)

      ping = false

      if client.connected?
        begin
          ping = client.ping?
        rescue StandardError
          # pass
        end
      end

      @osctld_responsive.set(ping ? 1 : 0)

      if client.connected? && ping
        st = client.status

        @osctld_initialized.set(st[:initialized] ? 1 : 0)
        @osctld_start_time.set(st[:started_at].to_i)
      else
        @osctld_initialized.set(0)
        @osctld_start_time.set(0)
      end
    end
  end
end
