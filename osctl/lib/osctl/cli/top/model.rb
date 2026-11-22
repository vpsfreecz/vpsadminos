require 'libosctl'
require 'securerandom'

module OsCtl::Cli
  class Top::Model
    MODES = %i[realtime cumulative].freeze

    class InvalidSample < StandardError; end

    attr_reader :containers, :collectors
    attr_accessor :mode

    def initialize(enable_iostat: true, enable_netif: true, enable_zfs: true)
      @mutex = Mutex.new
      @generation = 0
      @sequence = 0
      @epoch = SecureRandom.uuid
      @snapshots = {}
      @collectors = { netif: enable_netif, zfs: enable_zfs, iostat: enable_zfs && enable_iostat }.freeze
      @monitor = Top::Monitor.new(self)
      @iostat = iostat_enabled? ? OsCtl::Lib::Zfs::IOStat.new : nil
      @host = Top::Host.new(iostat, enable_netif:, enable_zfs:)
      @mode = :realtime
      @monitor.subscribe
      open
    end

    def iostat_enabled?
      collectors[:iostat]
    end

    def netif_enabled?
      collectors[:netif]
    end

    def zfs_enabled?
      collectors[:zfs]
    end

    def setup
      client.cmd_data!(:pool_list).each { |v| host.pools << v[:name] } if zfs_enabled?
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

    # Presentation may copy/sort a snapshot, but cannot acquire or restamp it.
    def data
      sync { copy_data(@snapshots.fetch(mode, {})) }
    end

    def has_pool?(pool)
      sync { host.pools.include?(pool) }
    end

    def add_pool(pool)
      return unless zfs_enabled?

      sync do
        host.pools << pool unless host.pools.include?(pool)
        changed!(:pool, pool)
      end
      iostat.add_pool(pool) if iostat
    end

    def remove_pool(pool)
      return unless zfs_enabled?

      sync do
        host.pools.delete(pool)
        changed!(:pool, pool)
      end
      iostat.remove_pool(pool) if iostat
    end

    def add_ct(pool, id)
      # Monitor lookups use their own connection, never the measuring client's
      # stream or the model publication mutex.
      with_client do |lookup|
        attrs = lookup.cmd_data!(:ct_show, pool:, id:, read_hostname: false)
        ct = new_container(attrs)
        if netif_enabled?
          ct.netifs = begin
            read_netifs(lookup, pool:, id:)
          rescue OsCtl::Client::Error, SystemCallError, IOError
            nil
          end
        end
        sync do
          unless index[ct.ident]
            containers << ct
            index << ct
            changed!(:lifecycle, ct.ident)
          end
        end
      end
    rescue OsCtl::Client::Error, SystemCallError, IOError
      sync { missing_lifecycle(pool, id) }
    end

    def remove_ct(ct)
      sync do
        current = index[ct.ident]
        if current
          containers.delete(current)
          index.delete(current)
          changed!(:lifecycle, ct.ident)
        end
      end
    end

    def find_ct(pool, id)
      sync { index["#{pool}:#{id}"] }
    end

    def has_ct?(pool, id)
      !find_ct(pool, id).nil?
    end

    def add_ct_netif(ct, name)
      return unless netif_enabled?

      attrs = with_client { |lookup| lookup.cmd_data!(:netif_show, pool: ct.pool, id: ct.id, name:) }
      sync do
        current = index[ct.ident]
        current.netifs << Top::Container::NetIf.new(attrs) if current&.netifs && !current.has_netif?(name)
        changed!(:netif, ct.ident)
      end
    rescue OsCtl::Client::Error, SystemCallError, IOError
      sync do
        current = index[ct.ident]
        current.netifs = nil if current
        changed!(:netif, ct.ident)
      end
    end

    def changed!(*_scope)
      @generation += 1
    end

    def missing_lifecycle(*)
      # Strict sampling keeps its existing event filter for unknown keys.
    end

    def monitor_ready; end

    def monitor_unavailable; end

    def sync(&)
      @mutex.owned? ? yield : @mutex.synchronize(&)
    end

    protected

    attr_reader :client, :nproc, :host, :subsystems, :monitor, :index, :iostat

    def monotonic_ns
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    end

    def open
      @client = OsCtl::Client.new
      client.open
      @subsystems = client.cmd_data!(:group_cgsubsystems) if OsCtl::Lib::CGroup.v1?
      load_initial_inventory
    end

    def load_initial_inventory
      @containers = read_inventory.map { |attrs| new_container(attrs) }
      rebuild_index
      return unless netif_enabled?

      begin
        netifs = client.cmd_data!(:netif_list).group_by { |attrs| "#{attrs[:pool]}:#{attrs[:ctid]}" }
        containers.each { |ct| ct.netifs = netifs.fetch(ct.ident, []).map { |attrs| Top::Container::NetIf.new(attrs) } }
      rescue StandardError
        containers.each { |ct| ct.netifs = nil }
      end
    end

    def with_client
      lookup = OsCtl::Client.new
      begin
        lookup.open
        opened = true
        yield lookup
      ensure
        lookup.close if opened
      end
    end

    def new_container(attrs)
      Top::Container.new(attrs, enable_netif: netif_enabled?, enable_zfs: zfs_enabled?)
    end

    def read_netifs(lookup, **opts)
      lookup.cmd_data!(:netif_list, **opts).map { |attrs| Top::Container::NetIf.new(attrs) }
    end

    def read_inventory
      rows = client.cmd_data!(:ct_list, read_hostname: false)
      raise InvalidSample, 'invalid_inventory' unless rows.is_a?(Array)

      keys = []
      rows.each do |ct|
        unless ct.is_a?(Hash) && %i[pool id state].all? { |k| ct[k].is_a?(String) && !ct[k].empty? }
          raise InvalidSample, 'invalid_inventory'
        end

        key = [ct[:pool], ct[:id]]
        raise InvalidSample, 'invalid_inventory' if keys.include?(key)

        keys << key
        next unless ct[:state] == 'running'
        unless ct[:group_path].is_a?(String) && !ct[:group_path].empty? && ct[:init_pid].is_a?(Integer) && ct[:init_pid] > 0
          raise InvalidSample, 'invalid_inventory'
        end
      end
      rows
    end

    def running_identities(rows)
      rows.select { |ct| ct[:state] == 'running' }.map do |ct|
        ct.values_at(:pool, :id, :group_path, :init_pid)
      end.sort
    end

    def reconcile_inventory(attrs, prepared)
      @containers = attrs.map do |ct_attrs|
        ident = "#{ct_attrs[:pool]}:#{ct_attrs[:id]}"
        ct = index[ident] || prepared.fetch(ident)
        ct.update(ct_attrs)
        ct
      end
      rebuild_index
    end

    def rebuild_index
      @index = OsCtl::Lib::Index.new(&:ident)
      containers.each { |ct| index << ct }
    end

    def valid_load?(values)
      values.is_a?(Array) && values.size == 3 && values.all? { |v| v.is_a?(Numeric) && v.finite? && v >= 0 }
    end

    def copy_data(value)
      case value
      when Hash then value.transform_values { |v| copy_data(v) }
      when Array then value.map { |v| copy_data(v) }
      else value
      end
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
