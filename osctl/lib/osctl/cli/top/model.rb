require 'libosctl'

module OsCtl::Cli
  class Top::Model
    MODES = %i[realtime cumulative].freeze

    attr_reader :containers
    attr_accessor :mode

    def initialize(enable_iostat: true)
      @mutex = Mutex.new
      @monitor = Top::Monitor.new(self)
      @iostat = enable_iostat ? OsCtl::Lib::Zfs::IOStat.new : nil
      @host = Top::Host.new(iostat)
      @mode = :realtime

      @monitor.subscribe
      open
    end

    def iostat_enabled?
      !iostat.nil?
    end

    def setup
      client.cmd_data!(:pool_list).each { |v| host.pools << v[:name] }
      monitor.start

      if iostat
        iostat.pools = host.pools
        iostat.start
      end

      @nproc = `nproc`.strip.to_i
      measure
    end

    def stop
      iostat.stop if iostat
    end

    def measure
      host.measure(subsystems)

      sync do
        containers.each do |ct|
          next unless ct.running?

          begin
            ct.measure(host, subsystems)
          rescue Top::Measurement::Error
            ct.state = :error
          end
        end

        begin
          @ct_lavgs = OsCtl::Lib::LoadAvgReader.read_for(containers)
        rescue StandardError
          @ct_lavgs = {}
        end
      end
    end

    def data
      return {} unless host.setup?

      mem = OsCtl::Lib::MemInfo.new
      lavg = OsCtl::Lib::LoadAvg.new

      host_result = host.result(mode, mem, lavg)
      host_cpu = host.cpu_result
      host_zfs = host.zfs_result
      sum_ct_cpu_hz = 0
      cts = []

      sync do
        containers.each do |ct|
          next if !ct.running? || !ct.setup?

          ct_result = ct.result(mode)
          update_host_result(host_result, ct_result)

          ct_lavg = @ct_lavgs[ct.ident]

          ct_data = {
            pool: ct.pool,
            id: ct.id,
            cpu_package_inuse: ct.cpu_package_inuse,
            init_pid: ct.init_pid,
            loadavg: ct_lavg ? ct_lavg.averages : [0.0, 0.0, 0.0]
          }.merge(ct_result)

          if mode == :realtime
            ct_cpu_hz = ct_result[:cpu_user_hz] + ct_result[:cpu_system_hz]
            sum_ct_cpu_hz += ct_cpu_hz

            ct_data.update(
              cpu_usage: calc_cpu_usage(ct_cpu_hz, host_cpu.total)
            )
          end

          cts << ct_data
        end
      end

      host_data = {
        id: host.id,
        loadavg: lavg.to_a
      }.merge(host_result)

      if mode == :realtime
        host_data.update(
          cpu_usage: calc_cpu_usage(host_cpu.total_used - sum_ct_cpu_hz, host_cpu.total)
        )
      end

      cts << host_data

      {
        cpu: calc_host_cpu_usage(host_cpu),
        loadavg: lavg.to_a,
        memory: {
          total: mem.total * 1024,
          used: mem.used * 1024,
          free: mem.free * 1024,
          buffers: mem.buffers * 1024,
          cached: mem.cached * 1024,
          swap_total: mem.swap_total * 1024,
          swap_used: mem.swap_used * 1024,
          swap_free: mem.swap_free * 1024
        },
        zfs: host_zfs,
        containers: cts
      }
    end

    def has_pool?(pool)
      host.pools.include?(pool)
    end

    def add_pool(pool)
      host.pools << pool
      iostat.add_pool(pool) if iostat
    end

    def remove_pool(pool)
      host.pools.delete(pool)
      iostat.remove_pool(pool) if iostat
    end

    def add_ct(pool, id)
      ct = client.cmd_data!(:ct_show, pool:, id:)
      ct = Top::Container.new(ct)
      ct.netifs = client.cmd_data!(
        :netif_list,
        id:,
        pool:
      ).map do |netif_attrs|
        Top::Container::NetIf.new(netif_attrs)
      end

      sync do
        containers << ct
        index << ct
      end
    rescue OsCtl::Client::Error
      raise "Container #{pool}:#{id} announced, but not found"
    end

    def remove_ct(ct)
      sync do
        containers.delete(ct)
        index.delete(ct)
      end
    end

    def find_ct(pool, id)
      sync { index["#{pool}:#{id}"] }
    end

    def has_ct?(pool, id)
      !find_ct(pool, id).nil?
    end

    def add_ct_netif(ct, name)
      attrs = client.cmd_data!(:netif_show, pool: ct.pool, id: ct.id, name:)
      sync { ct.netifs << Top::Container::NetIf.new(attrs) }
    rescue OsCtl::Client::Error
      raise "Unable to find netif #{name} for container #{ct.pool}:#{ct.id}"
    end

    def sync(&)
      if @mutex.owned?
        yield
      else
        @mutex.synchronize(&)
      end
    end

    protected

    attr_reader :client, :nproc, :host, :subsystems, :monitor, :index, :iostat

    def open
      @client = OsCtl::Client.new
      @client.open
      @subsystems = client.cmd_data!(:group_cgsubsystems) if OsCtl::Lib::CGroup.v1?
      @index = OsCtl::Lib::Index.new { |ct| "#{ct.pool}:#{ct.id}" }
      @containers = client.cmd_data!(:ct_list).map do |ct_attrs|
        ct = Top::Container.new(ct_attrs)
        index << ct
        ct
      end

      client.cmd_data!(:netif_list).each do |netif_attrs|
        ct = index["#{netif_attrs[:pool]}:#{netif_attrs[:ctid]}"]
        next if ct.nil?

        ct.netifs << Top::Container::NetIf.new(netif_attrs)
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
      if part < 0
        0.0
      else
        part.to_f / total * 100 * nproc
      end
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
