require 'osctl/exporter/collectors/base'

module OsCtl::Exporter
  class Collectors::OsCtld < Collectors::Base
    def setup
      @osctld_up = registry.gauge(
        :osctld_up,
        docstring: '1 if osctld is up and running, 0 if it is down',
      )

      @osctld_responsive = registry.gauge(
        :osctld_responsive,
        docstring: '1 if osctld is responding, 0 if not',
      )
    end

    def collect(client)
      @osctld_up.set(client.connected? ? 1 : 0)

      ping = false

      if client.connected?
        begin
          ping = client.ping?
        rescue
          # pass
        end
      end

      @osctld_responsive.set(ping ? 1 : 0)
    end
  end
end
