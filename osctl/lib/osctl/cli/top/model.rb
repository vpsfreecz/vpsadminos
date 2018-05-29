require 'thread'

module OsCtl::Cli
  class Top::Model
    MODES = %i(realtime cumulative)

    attr_reader :containers
    attr_accessor :mode

    def initialize
      @mutex = Mutex.new
      @monitor = Top::Monitor.new(self)
      @host = Top::Host.new
      @mode = :realtime
      open
    end

    def setup
      monitor.start
      @nproc = `nproc`.strip.to_i
      measure
    end

    def measure
      host.measure(subsystems)

      sync do
        containers.each do |ct|
          next unless ct.running?
          ct.measure(subsystems)
        end
      end
    end

    def data
      return [] unless host.setup?

      mem = Top::MemInfo.new
      arc = Top::ArcStats.new
      host_result = host.result(mode, mem)
      host_cpu = host.cpu_result
      sum_ct_cpu_hz = 0
      cts = []

      sync do
        containers.each do |ct|
          next if !ct.running? || !ct.setup?

          ct_result = ct.result(mode)
          update_host_result(host_result, ct_result)
          ct_data = {pool: ct.pool, id: ct.id}.merge(ct_result)

          if mode == :realtime
            ct_cpu_hz = ct_result[:cpu_user_hz] + ct_result[:cpu_system_hz]
            sum_ct_cpu_hz += ct_cpu_hz

            ct_data.update(
              cpu_usage: calc_cpu_usage(ct_cpu_hz, host_cpu.total),
            )
          end

          cts << ct_data
        end
      end

      host_data = {id: host.id}.merge(host_result)

      if mode == :realtime
        host_data.update(
          cpu_usage: calc_cpu_usage(host_cpu.total_used - sum_ct_cpu_hz, host_cpu.total),
        )
      end

      cts << host_data

      {
        cpu: calc_host_cpu_usage(host_cpu),
        memory: {
          total: mem.total * 1024,
          used: mem.used * 1024,
          free: mem.free * 1024,
          buffers: mem.buffers * 1024,
          cached: mem.cached * 1024,
          swap_total: mem.swap_total * 1024,
          swap_used: mem.swap_cached * 1024,
          swap_free: mem.swap_free * 1024,
        },
        zfs: {
          arc: {
            c_max: arc.c_max,
            c: arc.c,
            size: arc.size,
            hit_rate: arc.hit_rate,
          },
          l2arc: {
            size: arc.l2_size,
            asize: arc.l2_asize,
            hit_rate: arc.l2_hit_rate,
          },
        },
        containers: cts,
      }
    end

    def add_ct(pool, id)
      ct = client.cmd_data!(:ct_show, pool: pool, id: id)
      ct = Top::Container.new(ct)
      ct.netifs = client.cmd_data!(
        :netif_list,
        id: id,
        pool: pool
      ).map do |netif_attrs|
        Top::Container::NetIf.new(netif_attrs)
      end

      sync { containers << ct }

    rescue OsCtl::Client::Error
      fail "Container #{pool}:#{id} announced, but not found"
    end

    def remove_ct(ct)
      sync { containers.delete(ct) }
    end

    def add_ct_netif(ct, name)
      attrs = client.cmd_data!(:netif_show, pool: ct.pool, id: ct.id, name: name)
      sync { ct.netifs << Top::Container::NetIf.new(attrs) }

    rescue OsCtl::Client::Error
      fail "Unable to find netif #{name} for container #{ct.pool}:#{ct.id}"
    end

    def sync
      if @mutex.owned?
        yield
      else
        @mutex.synchronize { yield }
      end
    end

    protected
    attr_reader :client, :nproc, :host, :subsystems, :monitor

    def open
      @client = OsCtl::Client.new
      @client.open
      @subsystems = client.cmd_data!(:group_cgsubsystems)
      @containers = client.cmd_data!(:ct_list).map do |ct_attrs|
        ct = Top::Container.new(ct_attrs)
        ct.netifs = client.cmd_data!(
          :netif_list,
          id: ct.id,
          pool: ct.pool
        ).map { |netif_attrs| Top::Container::NetIf.new(netif_attrs) }
        ct
      end
    end

    def update_host_result(host_result, ct_result)
      ct_result.each do |k, v|
        if v.is_a?(Hash)
          host_result[k] = update_host_result(host_result[k], v)

        else
          host_result[k] -= v
          host_result[k] = 0 if host_result[k] < 0
        end
      end

      host_result
    end

    def calc_cpu_usage(part, total)
      part.to_f / total * 100 * nproc
    end

    def calc_host_cpu_usage(cpu)
      ret = {}

      cpu.each_pair do |k, v|
        ret[k] = v.to_f / cpu.total * 100
      end

      ret
    end
  end
end
