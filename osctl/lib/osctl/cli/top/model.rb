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
      @baseline_started = nil
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

    def measure
      started = monotonic_ns
      generation = sync do
        @sequence += 1
        @generation
      end
      begin
        raise InvalidSample, 'invalid_cpu_count' unless nproc && nproc > 0

        attrs = read_inventory
        new_cts = prepare_new_containers(attrs)
        measured_host, measured_cts, baseline = sync do
          raise InvalidSample, 'inventory_changed' unless generation == @generation

          reconcile_inventory(attrs, new_cts)
          [host.snapshot, containers.map(&:snapshot), @baseline_started]
        end
        running = measured_cts.select(&:running?)
        runs = running.to_h { |ct| [ct.ident, init_start_time(ct.init_pid)] }
        running.each do |ct|
          if ct.init_start_time_ticks && ct.init_start_time_ticks != runs[ct.ident]
            ct.reset_measurements
          end
          ct.init_start_time_ticks = runs[ct.ident]
        end

        # Acquisition is outside the publication lock. These are the ordinary
        # Host/Container/Measurement objects, copied with their existing history.
        measured_host.measure(subsystems)
        running.each do |ct|
          ct.measure(measured_host, subsystems)
          raise InvalidSample, ct.current_measurement.core_error if ct.current_measurement.core_error
        end
        mem = OsCtl::Lib::MemInfo.new
        lavg = OsCtl::Lib::LoadAvg.new
        validate_host_inputs(mem, lavg)
        loads = running.empty? ? {} : OsCtl::Lib::LoadAvgReader.read_for(running)
        running.each do |ct|
          entry = loads[ct.ident]
          raise InvalidSample, 'missing_container_load' unless entry && valid_load?(entry.averages)
        end
        unless running_identities(attrs) == running_identities(read_inventory)
          raise InvalidSample, 'inventory_changed'
        end

        running.each do |ct|
          raise InvalidSample, 'run_changed' unless runs[ct.ident] == init_start_time(ct.init_pid)
        end

        reason = measured_host.core_delta_error || running.filter_map(&:core_delta_error).first
        if reason || baseline.nil? || baseline >= started
          reason ||= baseline.nil? ? 'initial_baseline' : 'invalid_window'
          measured_host.reset_measurements(keep_current: true)
          measured_cts.each { |ct| ct.reset_measurements(keep_current: true) }
          baseline = nil
        end
        snapshots = MODES.to_h do |projection_mode|
          [projection_mode, project(measured_host, running, mem, lavg, loads, projection_mode, reason)]
        end
        completed = monotonic_ns
        metadata = sample_metadata(started, completed, reason, baseline)
        snapshots.each_value { |snapshot| snapshot.update(metadata) }
        sync do
          raise InvalidSample, 'inventory_changed' unless generation == @generation

          @host = measured_host
          @containers = measured_cts
          rebuild_index
          @baseline_started = started
          @snapshots = snapshots
        end
      rescue StandardError => e
        reason = e.is_a?(InvalidSample) ? e.message : 'required_read_failed'
        completed = monotonic_ns
        sync do
          host.reset_measurements
          containers.each(&:reset_measurements)
          @baseline_started = nil
          @snapshots = MODES.to_h { |m| [m, invalid_snapshot(started, completed, reason)] }
        end
      end
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
        changed!
      end
      iostat.add_pool(pool) if iostat
    end

    def remove_pool(pool)
      return unless zfs_enabled?

      sync do
        host.pools.delete(pool)
        changed!
      end
      iostat.remove_pool(pool) if iostat
    end

    def add_ct(pool, id)
      # Monitor lookups use their own connection, never the measuring client's
      # stream or the model publication mutex.
      with_client do |lookup|
        attrs = lookup.cmd_data!(:ct_show, pool:, id:, read_hostname: false)
        ct = new_container(attrs)
        ct.netifs = read_netifs(lookup, pool:, id:) if netif_enabled?
        sync do
          unless index[ct.ident]
            containers << ct
            index << ct
            changed!
          end
        end
      end
    rescue OsCtl::Client::Error
      raise "Container #{pool}:#{id} announced, but not found"
    end

    def remove_ct(ct)
      sync do
        current = index[ct.ident]
        if current
          containers.delete(current)
          index.delete(current)
          changed!
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
        current.netifs << Top::Container::NetIf.new(attrs) if current && !current.has_netif?(name)
        changed!
      end
    rescue OsCtl::Client::Error
      raise "Unable to find netif #{name} for container #{ct.pool}:#{ct.id}"
    end

    def changed!
      @generation += 1
    end

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
      @containers = read_inventory.map { |attrs| new_container(attrs) }
      rebuild_index
      return unless netif_enabled?

      client.cmd_data!(:netif_list).each do |attrs|
        ct = index["#{attrs[:pool]}:#{attrs[:ctid]}"]
        ct.netifs << Top::Container::NetIf.new(attrs) if ct
      end
    end

    def with_client
      lookup = OsCtl::Client.new
      begin
        lookup.open
        yield lookup
      ensure
        lookup.close
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

    def prepare_new_containers(attrs)
      known = sync { containers.map(&:ident) }
      attrs.reject { |ct| known.include?("#{ct[:pool]}:#{ct[:id]}") }.to_h do |ct_attrs|
        ct = new_container(ct_attrs)
        ct.netifs = read_netifs(client, pool: ct.pool, id: ct.id) if netif_enabled?
        [ct.ident, ct]
      end
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

    def init_start_time(pid)
      stat = File.read("/proc/#{pid}/stat")
      closing = stat.rindex(')')
      raise InvalidSample, 'invalid_run' unless closing && stat.split.first == pid.to_s

      fields = stat[closing + 1..].split
      ticks = Integer(fields.fetch(19), 10)
      raise InvalidSample, 'invalid_run' unless ticks > 0 && !%w[Z X x].include?(fields[0])

      ticks
    rescue ArgumentError, IndexError
      raise InvalidSample, 'invalid_run'
    end

    def valid_load?(values)
      values.is_a?(Array) && values.size == 3 && values.all? { |v| v.is_a?(Numeric) && v.finite? && v >= 0 }
    end

    def validate_host_inputs(mem, lavg)
      values = %i[total used free buffers cached swap_total swap_used swap_free].map { |k| mem.public_send(k) }
      return if values.all? { |v| v.is_a?(Numeric) && v.finite? && v >= 0 } && valid_load?(lavg.to_a)

      raise InvalidSample, 'invalid_host_value'
    end

    def project(measured_host, running, mem, lavg, loads, projection_mode, reason)
      host_result = reason ? result_for(measured_host, projection_mode, reason) : measured_host.result(projection_mode, mem, lavg)
      host_result[:memory] = mem.used * 1024
      host_result[:nproc] = lavg.total
      host_cpu = reason.nil? ? measured_host.cpu_result : nil
      sum_ct_cpu_hz = 0
      cts = running.map do |ct|
        result = result_for(ct, projection_mode, reason)
        %i[tx rx zfsio].each { |k| host_result[k] = nil if result[k].nil? }
        update_host_result(host_result, result)
        row = {
          pool: ct.pool, id: ct.id, cpu_package_inuse: ct.cpu_package_inuse,
          init_pid: ct.init_pid, init_start_time_ticks: ct.init_start_time_ticks,
          valid: reason.nil?, invalid_reason: reason, loadavg: loads.fetch(ct.ident).averages
        }.merge(result)
        if projection_mode == :realtime
          hz = reason.nil? ? result[:cpu_user_hz] + result[:cpu_system_hz] : nil
          sum_ct_cpu_hz += hz if hz
          row[:cpu_usage] = hz && calc_cpu_usage(hz, host_cpu.total)
        end
        row
      end
      host_row = {
        pool: nil, id: measured_host.id, init_pid: nil, init_start_time_ticks: nil,
        valid: reason.nil?, invalid_reason: reason, loadavg: lavg.to_a
      }.merge(host_result)
      if projection_mode == :realtime
        host_row[:cpu_usage] = host_cpu && calc_cpu_usage(host_cpu.total_used - sum_ct_cpu_hz, host_cpu.total)
      end
      cts << host_row
      {
        cpu: host_cpu && calc_host_cpu_usage(host_cpu), loadavg: lavg.to_a,
        memory: %i[total used free buffers cached swap_total swap_used swap_free].to_h { |k| [k, mem.public_send(k) * 1024] },
        zfs: measured_host.zfs_result, containers: cts
      }
    end

    def result_for(ct, projection_mode, reason)
      return ct.result(projection_mode) unless reason

      ct.current_measurement.data.to_h do |k, v|
        [k, %i[memory memory_limit cpu_limit nproc].include?(k) ? v : nil]
      end
    end

    def sample_metadata(started, completed, reason, baseline)
      {
        top_schema: 1, epoch: @epoch, sequence: @sequence, collectors:,
        sample_started_monotonic_ns: started, sample_completed_monotonic_ns: completed,
        measurement_window_started_monotonic_ns: baseline,
        measurement_window_completed_monotonic_ns: completed,
        complete: reason.nil?, invalid_reason: reason
      }
    end

    def invalid_snapshot(started, completed, reason)
      sample_metadata(started, completed, reason, nil).merge(
        cpu: nil, memory: nil, loadavg: nil, zfs: nil,
        containers: [{ pool: nil, id: '[host]', init_pid: nil, init_start_time_ticks: nil,
                       cpu_usage: nil, memory: nil, memory_limit: nil, cpu_limit: nil,
                       loadavg: nil, tx: nil, rx: nil, zfsio: nil, valid: false, invalid_reason: reason }]
      )
    end

    def copy_data(value)
      case value
      when Hash then value.transform_values { |v| copy_data(v) }
      when Array then value.map { |v| copy_data(v) }
      else value
      end
    end

    def update_host_result(host_result, ct_result)
      ct_result.each do |k, v|
        next if host_result[k].nil? || v.nil?

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
