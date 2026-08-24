require 'osctl/exporter/collectors/base'

module OsCtl::Exporter
  class Collectors::Pool < Collectors::Base
    include OsCtl::Lib::Utils::Log

    def setup
      add_metric(
        :pools,
        :gauge,
        :osctl_pool_count,
        docstring: 'Number of imported pools',
        labels: [:state]
      )

      add_metric(
        :pool_containers_config,
        :gauge,
        :osctl_pool_containers_config_count,
        docstring: 'Number of pool containers by configuration state',
        labels: %i[pool state]
      )

      add_metric(
        :pool_containers_runtime,
        :gauge,
        :osctl_pool_containers_runtime_count,
        docstring: 'Number of pool containers by runtime state',
        labels: %i[pool state]
      )
    end

    def collect(client)
      collect_pools(client)
      collect_pool_containers(client)
    end

    protected

    attr_reader :pools, :pool_containers_config, :pool_containers_runtime

    def collect_pools(client)
      states = {
        importing: 0,
        active: 0,
        disabled: 0
      }

      client.list_pools.each do |pool|
        st = pool[:state].to_sym

        unless states.has_key?(st)
          log(:warn, "Pool #{pool[:name]} is in invalid state '#{st}'")
          next
        end

        states[st] += 1
      end

      states.each do |st, cnt|
        pools.set(cnt, labels: { state: st })
      end
    end

    def collect_pool_containers(client)
      pools = client.list_pools
      pool_config_states = {}
      pool_runtime_states = {}

      pools.each do |pool|
        pool_config_states[pool[:name]] =
          Collectors::Container::CONFIG_STATES.to_h { |state| [state, 0] }
        pool_runtime_states[pool[:name]] =
          Collectors::Container::RUNTIME_STATES.to_h { |state| [state, 0] }
      end

      client.list_containers.each do |ct|
        pool = ct[:pool]
        next unless pool_config_states.has_key?(pool)

        config_state = ct[:config_state].to_sym
        runtime_state = ct[:runtime_state].to_sym
        pool_config_states[pool][config_state] += 1 \
          if pool_config_states[pool].has_key?(config_state)
        pool_runtime_states[pool][runtime_state] += 1 \
          if pool_runtime_states[pool].has_key?(runtime_state)
      end

      pool_config_states.each do |pool, states|
        states.each do |state, count|
          pool_containers_config.set(count, labels: { pool:, state: })
        end
      end

      pool_runtime_states.each do |pool, states|
        states.each do |state, count|
          pool_containers_runtime.set(count, labels: { pool:, state: })
        end
      end
    end
  end
end
