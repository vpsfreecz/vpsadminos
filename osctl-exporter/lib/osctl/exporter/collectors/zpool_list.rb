require 'osctl/exporter/collectors/base'

module OsCtl::Exporter
  class Collectors::ZpoolList < Collectors::Base
    def setup
      @zpool_list_success = registry.gauge(
        :zpool_list_success,
        docstring: 'Process exit code'
      )
      @zpool_list_parse_success = registry.gauge(
        :zpool_list_parse_success,
        docstring: 'Parsing successful'
      )
      add_metric(
        :zpool_list_health,
        :gauge,
        :zpool_list_health,
        docstring: 'Pool healthy',
        labels: [:pool]
      )
      add_metric(
        :zpool_list_fragmentation,
        :gauge,
        :zpool_list_fragmentation,
        docstring: 'Pool fragmentation',
        labels: [:pool]
      )
      add_metric(
        :zpool_list_capacity,
        :gauge,
        :zpool_list_capacity,
        docstring: 'Pool capacity',
        labels: [:pool]
      )
    end

    def collect(_client)
      list = `zpool list -Hp -o name,health,fragmentation,capacity`

      if $?.exitstatus != 0
        @zpool_list_success.set(0)
        return
      end

      @zpool_list_success.set(1)
      @zpool_list_parse_success.set(1)

      list.split("\n").each do |line|
        name, health, fragmentation, capacity = line.split

        @zpool_list_health.set(health == 'ONLINE' ? 1 : 0, labels: { pool: name })
        @zpool_list_fragmentation.set(fragmentation.to_i, labels: { pool: name })
        @zpool_list_capacity.set(capacity.to_i, labels: { pool: name })
      end
    end
  end
end
