require 'osctl/cli/top/model'

module OsCtl::Cli
  # One sweep, with independent histories for display and strict eligibility.
  # Neither history is populated from the other projection's published rows.
  class Top::PartialModel < Top::Model
    class MonitorLost < StandardError; end

    attr_reader :sample_wakeup

    Row = Struct.new(:ct, :start_run, :finish_run, :read_error, keyword_init: true) do
      def ticks = start_run&.ticks

      def verified? = ticks && ticks == finish_run&.ticks

      def identity
        [ct.ident, ct.group_path, ct.init_pid, ticks]
      end

      def measurement
        ct.current_measurement
      end
    end

    Sweep = Struct.new(:sequence, :started, :generation, :between, :initial, :first_error, :last, :last_error,
                       :inventory_generation, :machine, :rows, :mem, :load, :loads, :read_error,
                       :catalog, keyword_init: true)
    History = Struct.new(:started, :machine, :rows, :origins, :population_matches, :closed, keyword_init: true)

    INVENTORY_WAIT_SECONDS = 0.25
    CORE_GAUGES = %i[memory memory_limit cpu_limit nproc].freeze
    SOURCES = %i[cpu_us tx rx zfsio].freeze

    def initialize(json: true, **)
      @changes = {}
      @monitor_coverage = :pending
      @json = json
      @sample_wakeup = OsCtl::Lib::Queue.new if json
      super(**)
    end

    def setup
      check_monitor!
      super
    rescue OsCtl::Client::Error, SystemCallError, IOError
      check_monitor!
      raise
    end

    def stop
      if (worker = @inventory_read)
        @inventory_read = nil
        worker.kill
        worker.join
      end
    ensure
      super
    end

    def changed!(type = :lifecycle, key = nil)
      super
      @changes[[type, key]] = true
      return unless @projecting_changes

      @projecting_changes[[type, key]] = true if key.nil? || @projection_keys.include?(key)
      @projecting_changes[[type, :outside_sweep]] = true
    end

    def monitor_ready
      sync { @monitor_coverage = :active if @monitor_coverage == :pending }
    end

    def monitor_unavailable(startup: false)
      sync do
        next if @monitor_coverage == :unavailable

        @monitor_coverage = :unavailable
        @monitor_loss = startup ? :subscribe_failed : :coverage_lost
        changed!(:monitor)
        sample_wakeup&.push(:monitor_loss)
      end
    end

    def check_monitor!
      return unless @json

      case sync { @monitor_loss }
      when :subscribe_failed
        raise MonitorLost, 'ct top: unable to subscribe to osctld events'
      when :coverage_lost
        raise MonitorLost, 'ct top: lost osctld event coverage; restart the sampler'
      end
    end

    def measure
      sweep = acquire
      projection_keys = (sweep.rows.keys + sweep.rows.values.map { |row| row.ct.pool }).to_set
      version, during, labels, coverage = sync do
        @projecting_changes = {}
        @projection_keys = projection_keys
        [@generation, @changes.dup, containers.to_h { |ct| [ct.ident, ct.cpu_package_inuse] }, @monitor_coverage]
      end
      history = build_history(sweep, during)
      reason, hard = strict_verdict(sweep, history, version)
      unless coverage == :active
        reason = 'monitor_unavailable'
        hard = true
      end
      frames = MODES.to_h do |mode|
        [mode, project_partial(sweep, history, during, labels, mode, reason)]
      end
      decision_cpu = complete_cpu(history) if @json && reason.nil?
      completed = monotonic_ns
      sync do
        hard = publish_sweep(sweep, history, frames, version, reason, hard)
        frames.each_value do |frame|
          frame.update(sample_completed_monotonic_ns: completed, measurement_window_completed_monotonic_ns: completed)
        end
        @decision_cpu = decision_cpu unless hard
        @decision_cpu = nil if hard
        @strict_previous = hard ? nil : history
        @previous = history
        @snapshots = frames
      end
    ensure
      sync do
        @projecting_changes = nil
        @projection_keys = nil
      end
    end

    def json_data
      frame, decision_cpu = sync { [@snapshots[:realtime], @decision_cpu] }
      return {} unless frame

      record = copy_data(frame.except(:node_totals))
      record[:containers].each_with_index do |row, i|
        row.delete(:column_windows)
        row[:cpu_usage] = decision_cpu.fetch(i) if decision_cpu
      end
      record
    end

    def missing_lifecycle(pool, id)
      changed!(:lifecycle, "#{pool}:#{id}")
    end

    # Verify a fresh matching catalog entry before opening a pinned namespace FD.
    def current_run?(row, pid_namespace: nil)
      return false unless row[:run_verified]

      proof, = read_run(row, pid_namespace:)
      return false unless proof && proof.ticks == row[:init_start_time_ticks]

      sync do
        live = index[ident(row)]
        snapshot = @snapshots.fetch(:realtime, {})
        @monitor_coverage == :active && live&.running? && live.init_pid == row[:init_pid] && live.group_path == row[:group_path] &&
          !dirty?(@changes, :lifecycle, live.ident) && snapshot.fetch(:containers, []).any? do |ct|
            ct.values_at(:pool, :id, :group_path, :init_pid, :init_start_time_ticks, :run_verified) ==
              row.values_at(:pool, :id, :group_path, :init_pid, :init_start_time_ticks, :run_verified)
          end
      end
    end

    protected

    # The final fence only adjusts already prepared rows and histories. No
    # collector or projection runs here, regardless of incoming event rate.
    def publish_sweep(sweep, history, frames, version, reason, hard)
      late = @projecting_changes
      monitor_lost = @monitor_coverage != :active
      lifecycle = late.keys.any? { |type, _| type == :lifecycle }
      history.closed = false if monitor_lost || lifecycle
      if monitor_lost || version != @generation
        reason = 'inventory_changed' unless hard
        reason = 'monitor_unavailable' if monitor_lost
        hard = true
        frames.each_value { |frame| mask_frame(frame, history, late, reason, lifecycle, monitor_lost) }
      end
      history.rows.delete_if { |key, _| dirty?(late, :lifecycle, key) } if lifecycle
      publish_catalog(sweep, @changes) if sweep.last && !sweep.last_error && @generation == sweep.inventory_generation && !monitor_lost
      hard
    end

    def mask_frame(frame, history, late, reason, lifecycle, monitor_lost)
      frame.update(complete: false, invalid_reason: reason, measurement_window_started_monotonic_ns: nil,
                   inventory_complete: history.closed)
      frame[:state_counts] = nil if lifecycle || monitor_lost
      host_row = frame[:containers].last
      node = frame[:node_totals]
      network_changed = monitor_lost || late.keys.any? { |type, _| type == :netif }
      pool_changed = monitor_lost || late.keys.any? { |type, _| type == :pool }
      clear_rates(node, history, nil, %i[tx rx]) if network_changed
      if pool_changed
        clear_rates(node, history, nil, [:zfsio])
        frame[:zfs] = nil
      end
      clear_rates(host_row, history, nil, %i[tx rx]) if network_changed
      clear_rates(host_row, history, nil, [:zfsio]) if pool_changed
      if lifecycle || monitor_lost
        clear_rates(host_row, history, nil, %i[memory nproc cpu_usage cpu_us tx rx zfsio])
      end
      frame[:containers].each do |row|
        next unless row[:pool]

        key = ident(row)
        row[:cpu_package_inuse] = index[key]&.cpu_package_inuse if dirty?(late, :metadata, key)
        if dirty?(late, :lifecycle, key)
          clear_rates(row, history, key, SOURCES)
          row.update(unverified_fields('run_changed'))
          next
        end
        if monitor_lost
          clear_rates(row, history, key, SOURCES)
          row.update(cpu_usage: nil, cpu_baseline_sequence: nil, cpu_window_started_monotonic_ns: nil)
          row[:errors][:cpu_usage] = 'monitor_unavailable' if row[:run_verified]
        else
          clear_rates(row, history, key, %i[tx rx]) if dirty?(late, :netif, key)
          clear_rates(row, history, key, [:zfsio]) if dirty?(late, :pool, row[:pool])
        end
      end
    end

    def clear_rates(row, history, key, fields)
      fields.each do |field|
        row[field] = nil
        row[:column_windows].delete(field)
        history.origins.delete([key, field])
      end
    end

    def unverified_fields(reason)
      { init_pid: nil, init_start_time_ticks: nil, run_verified: false, cpu_usage: nil, cpu_baseline_sequence: nil,
        cpu_window_started_monotonic_ns: nil, memory: nil, memory_limit: nil, memory_limit_state: 'unknown',
        cpu_limit: nil, cpu_limit_state: 'unknown', nproc: nil, loadavg: nil, errors: { run: reason } }
    end

    def publish_catalog(sweep, during)
      # If an event changed lifecycle during the sweep, keep its live catalog
      # update rather than replacing it with potentially older RPC metadata.
      return if during.keys.any? { |type, _| type == :lifecycle }

      attrs = sweep.last.map do |row|
        if dirty?(during, :metadata, ident(row)) && (live = index[ident(row)])
          row.merge(cpu_package_inuse: live.cpu_package_inuse)
        else
          row
        end
      end
      reconcile_inventory(attrs, sweep.catalog)
      containers.each do |ct|
        ct.netifs ||= sweep.catalog.fetch(ct.ident).netifs unless dirty?(during, :netif, ct.ident)
      end
    end

    def open
      check_monitor!
      super
    rescue OsCtl::Client::Error, SystemCallError, IOError
      check_monitor!
      raise
    end

    def load_initial_inventory
      @bounded_inventory = @json && !netif_enabled? && !zfs_enabled?
      return super unless @bounded_inventory

      inventory, = sample_inventory
      @containers = Array(inventory).map { |attrs| new_container(attrs) }
      rebuild_index
    rescue StandardError
      @containers ||= []
      rebuild_index
    end

    def acquire
      sweep = sync do
        @sequence += 1
        sample = Sweep.new(sequence: @sequence, generation: @generation, started: monotonic_ns,
                           between: @changes, machine: host.snapshot, rows: {}, loads: {})
        @changes = {}
        sample
      end
      sweep.initial, sweep.first_error = sample_inventory
      catalog = sync { containers.to_h { |ct| [ct.ident, ct.snapshot] } }
      # Prepare both running and stopped catalog entries without socket I/O
      # under the publication lock.
      sweep.catalog = prepare_catalog(sweep.initial, catalog)
      Array(sweep.initial).each do |attrs|
        next unless attrs[:state] == 'running'

        ct = sweep.catalog.fetch(ident(attrs)).snapshot
        ct.update(attrs)
        start_run, error = read_run(attrs)
        sweep.rows[ct.ident] = Row.new(ct:, start_run:, read_error: error)
      end
      begin
        sweep.machine.measure(subsystems, clock: method(:counter_clock))
      rescue StandardError
        sweep.read_error = 'required_read_failed'
      end
      sweep.rows.each_value { |row| measure_row(row, sweep.machine) if row.start_run }
      sweep.mem = read_host_memory
      sweep.load = read_host_load
      sweep.loads = read_loads(sweep.rows)

      sweep.inventory_generation = sync { @generation }
      sweep.last, sweep.last_error = sample_inventory
      endings = Array(sweep.last).to_h { |attrs| [ident(attrs), attrs] }
      sweep.rows.each_value do |row|
        current = endings[row.ct.ident]
        if current && current[:state] == 'running' && !run_fields?(current)
          row.read_error ||= 'invalid_run'
          next
        end
        next unless matching_run?(row.ct, current)

        row.finish_run, error = read_run(current)
        row.read_error ||= error
      end
      ambiguous = sweep.rows.values.filter_map { |row| row.finish_run&.load_namespace }.tally
      sweep.rows.each_value do |row|
        ns = row.finish_run&.load_namespace
        sweep.loads.delete(row.ct.ident) if ns && ambiguous.fetch(ns) > 1
      end
      sweep.catalog = prepare_catalog(sweep.last, sweep.catalog, retry_unknown: false) if sweep.last
      sweep
    end

    def read_loads(rows)
      namespaces = rows.values.group_by { |row| row.start_run&.load_namespace }
      namespaces.delete(nil)
      namespaces = namespaces.filter_map { |ns, owners| [ns, owners.first.ct] if owners.one? }.to_h
      namespaces.empty? ? {} : OsCtl::Lib::LoadAvgReader.read_namespaces(namespaces)
    end

    def prepare_catalog(inventory, catalog, retry_unknown: true)
      Array(inventory).to_h do |attrs|
        key = ident(attrs)
        ct = catalog[key] || new_container(attrs)
        if netif_enabled? && (!catalog.has_key?(key) || (retry_unknown && ct.netifs.nil?))
          begin
            ct.netifs = read_netifs(client, pool: ct.pool, id: ct.id)
          rescue StandardError
            ct.netifs = nil
          end
        end
        [key, ct]
      end
    end

    def ident(attrs)
      "#{attrs[:pool]}:#{attrs[:id]}"
    end

    # At most one ct_list can be outstanding across both endpoints and all
    # sweeps. A late response supplies discovery hints for subsequent reads.
    def sample_inventory
      return inventory_result unless @bounded_inventory

      if @inventory_read
        return [@last_inventory, 'inventory_pending'] if @inventory_read.alive?

        finish_inventory_read
      end
      @inventory_read = Thread.new { inventory_result }
      return [@last_inventory, 'inventory_pending'] unless @inventory_read.join(INVENTORY_WAIT_SECONDS)

      inventory, error = finish_inventory_read
      [error == 'required_read_failed' ? @last_inventory : inventory, error]
    end

    def finish_inventory_read
      inventory, error = @inventory_read.value
      @inventory_read = nil
      @last_inventory = inventory if inventory
      [inventory, error]
    end

    def inventory_result
      inventory = @bounded_inventory ? with_client { |lookup| read_inventory(lookup) } : read_inventory
      if inventory.any? { |row| row[:id] == '[host]' } || inventory.map { |row| ident(row) }.uniq.size != inventory.size
        return [nil, 'invalid_inventory']
      end

      [inventory, nil]
    rescue StandardError => e
      [nil, e.is_a?(InvalidSample) ? e.message : 'required_read_failed']
    end

    def matching_run?(ct, attrs)
      attrs && attrs[:state] == 'running' && attrs[:group_path] == ct.group_path && attrs[:init_pid] == ct.init_pid
    end

    def run_fields?(attrs)
      pid = attrs[:init_pid]
      path = attrs[:group_path]
      pid.is_a?(Integer) && pid > 0 && path.is_a?(String) && !path.empty?
    end

    def read_run(attrs, pid_namespace: nil)
      return [nil, 'invalid_run'] unless run_fields?(attrs)

      [Top::RunIdentity.new(pid: attrs[:init_pid], id: attrs[:id], group_path: attrs[:group_path],
                            v1: OsCtl::Lib::CGroup.v1?, pid_namespace:), nil]
    rescue Top::RunIdentity::Invalid, SystemCallError, IOError
      [nil, 'invalid_run']
    end

    def measure_row(row, machine)
      row.ct.measure(machine, subsystems, clock: method(:counter_clock))
    rescue StandardError
      row.read_error ||= 'required_read_failed'
    end

    def counter_clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    end

    def read_host_memory
      mem = OsCtl::Lib::MemInfo.new
      %i[total used free buffers cached swap_total swap_used swap_free].to_h do |field|
        raw = mem.public_send(field)
        return { error: 'invalid_host_value' } unless numeric(raw)

        [field, raw * 1024]
      end
    rescue StandardError
      { error: 'required_read_failed' }
    end

    def read_host_load
      load = OsCtl::Lib::LoadAvg.new
      valid_load?(load.to_a) ? { values: load.to_a, nproc: load.total } : { error: 'invalid_host_value' }
    rescue StandardError
      { error: 'required_read_failed' }
    end

    def build_history(sweep, during)
      verified = sweep.rows.reject do |key, row|
        !row.verified? || dirty?(during, :lifecycle, key)
      end
      population_matches = sweep.initial && sweep.last && running_identities(sweep.initial) == running_identities(sweep.last)
      closed = population_matches && !sweep.first_error && !sweep.last_error && verified.size == sweep.rows.size && during.keys.none? { |type, _| type == :lifecycle }
      History.new(started: sweep.started, machine: sweep.machine, rows: verified,
                  population_matches: !!population_matches, closed: !!closed, origins: {})
    end

    def dirty?(changes, type, key = nil)
      changes[[type, nil]] || changes[[type, key]]
    end

    def strict_verdict(sweep, history, version)
      # Preserve the strict prerequisite order and its discard vs keep-current
      # distinction even when the partial frame can still report useful values.
      hard = sweep.first_error || (!nproc&.positive? && 'invalid_cpu_count') || sweep.machine.cpu_error
      sweep.rows.each_value do |row|
        hard ||= row.read_error || measurement_reason(row.measurement)
      end
      hard ||= 'required_read_failed' if sweep.machine.current_measurement&.required_read_failed
      hard ||= sweep.mem[:error] || sweep.load[:error] || sweep.read_error
      hard ||= 'missing_container_load' if sweep.rows.keys.any? { |key| !container_load(sweep, key) }
      hard ||= sweep.last_error
      hard ||= 'inventory_changed' unless history.population_matches
      hard ||= 'run_changed' unless history.closed
      hard ||= 'inventory_changed' if version != sweep.generation
      return [hard, true] if hard

      previous = @strict_previous
      return ['initial_baseline', false] unless previous
      return ['invalid_window', false] unless previous.started < sweep.started

      reason = host_delta_error(sweep.machine.current_cpu, previous.machine.current_cpu, wall: true)
      reason ||= history.rows.each_value.lazy.filter_map do |row|
        old = previous.rows[row.ct.ident]
        if !old || old.identity != row.identity || dirty?(sweep.between, :lifecycle, row.ct.ident)
          'initial_baseline'
        else
          row.measurement.delta_error(old.measurement)
        end
      end.first
      unless reason
        current = sweep.machine.current_cpu
        old = previous.machine.current_cpu
        reason = 'invalid_window' unless interval(current, old)
        reason ||= 'invalid_window' if history.rows.any? do |key, row|
          !interval(row.measurement, previous.rows.fetch(key).measurement)
        end
      end
      [reason, false]
    end

    def interval(current, previous)
      return unless current&.monotonic_ns && previous&.monotonic_ns

      ticks = current.monotonic_ns - previous.monotonic_ns
      ticks / 1_000_000_000.0 if ticks > 0
    end

    def measurement_reason(measurement)
      return 'required_read_failed' if !measurement || measurement.required_read_failed

      measurement.core_error
    end

    def host_delta_error(current, previous, wall: false)
      return 'initial_baseline' unless current && previous
      return 'invalid_window' if wall && current.time <= previous.time
      return 'counter_reset' if current.each_pair.any? { |key, value| value < previous[key] }
      return 'invalid_host_cpu_delta' unless current.total > previous.total

      nil
    end

    def numeric(value)
      value = value.raw if value.is_a?(OsCtl::Lib::Cli::Presentable)
      value if value.is_a?(Numeric) && value.finite? && value >= 0
    end

    def container_load(sweep, key)
      row = sweep.rows.fetch(key)
      namespace = row.start_run&.load_namespace
      return unless namespace && namespace == row.finish_run&.load_namespace

      entry = sweep.loads[key]
      entry.averages if entry && valid_load?(entry.averages)
    end

    # Full policy retains the established realtime rounding. These are CPU
    # values only, calculated from raw endpoints, not another projection.
    def complete_cpu(history)
      previous = @strict_previous
      cpu = history.machine.current_cpu.diff(previous.machine.current_cpu)
      total = 0
      usage = history.rows.map do |key, row|
        current = row.measurement
        old = previous.rows.fetch(key).measurement
        hz = cpu_hz(current, old, current.time - old.time)
        total += hz
        calc_cpu_usage(hz, cpu.total)
      end
      usage << calc_cpu_usage(cpu.total_used - total, cpu.total)
    end

    def cpu_hz(current, previous, elapsed)
      %i[cpu_user_hz cpu_system_hz].sum do |field|
        ((current.data[field] - previous.data[field]) / elapsed.to_f).round
      end
    end

    def project_partial(sweep, history, during, labels, mode, reason)
      current = sweep.machine.current_cpu
      old = @previous&.machine&.current_cpu
      cpu_interval = interval(current, old)
      cpu_error = sweep.machine.cpu_error || host_delta_error(current, old)
      cpu_error ||= 'invalid_window' unless cpu_interval && @previous.started < sweep.started
      cpu_error ||= 'invalid_cpu_count' unless nproc&.positive?
      cpu = host_cpu(current, old, cpu_interval) unless cpu_error
      inventory = if reason.nil?
                    sweep.initial
                  else
                    sweep.last || sweep.initial
                  end
      rows = Array(inventory).filter_map do |attrs|
        next unless attrs[:state] == 'running'

        key = ident(attrs)
        socket = dirty?(during, :metadata, key) ? labels[key] : attrs[:cpu_package_inuse]
        project_row(attrs, history, sweep, during, socket, mode, cpu, cpu_error)
      end
      memory = sweep.mem unless sweep.mem[:error]
      node, residual = project_host(sweep, history, during, mode, rows, memory, cpu)
      {
        top_schema: 2, epoch: @epoch, sequence: sweep.sequence, collectors:,
        sample_started_monotonic_ns: sweep.started, previous_sample_started_monotonic_ns: @previous&.started,
        measurement_window_started_monotonic_ns: reason.nil? ? @strict_previous.started : nil,
        complete: reason.nil?, invalid_reason: reason,
        inventory_complete: history.closed, state_counts: sweep.last_error ? nil : inventory&.map { |row| row[:state] }&.tally,
        cpu: cpu && calc_host_cpu_usage(cpu), loadavg: sweep.load[:values], memory:,
        zfs: sweep.machine.zfs_diff(@previous&.machine), node_totals: node,
        containers: rows << residual
      }
    end

    def host_cpu(current, previous, elapsed)
      Top::Host::Cpu.new(*current.each_pair.map { |key, value| (value - previous[key]) / elapsed })
    end

    def project_row(attrs, history, sweep, during, socket, mode, cpu, cpu_error)
      key = ident(attrs)
      row = history.rows[key]
      path = attrs[:group_path]
      path = nil unless path.is_a?(String) && !path.empty?
      row_data = unverified_fields(sweep.rows[key]&.read_error || 'run_changed').merge(
        pool: attrs[:pool], id: attrs[:id], group_path: path, cpu_package_inuse: socket, column_windows: {}
      )
      return row_data unless row

      row_data.update(init_pid: row.ct.init_pid, init_start_time_ticks: row.ticks, run_verified: true, errors: {})

      measurement = row.measurement
      row_data[:loadavg] = container_load(sweep, key)
      row_data.update(gauges(measurement))
      add_gauge_errors(row_data, measurement)
      previous = @previous&.rows&.[](key)
      previous = nil unless previous&.identity == row.identity && !dirty?(sweep.between, :lifecycle, key)
      old = previous&.measurement
      elapsed = interval(measurement, old)
      cpu_error ||= cpu_pair_error(measurement, old, elapsed)
      if cpu_error
        row_data[:errors][:cpu_usage] = cpu_error
      else
        href = cpu_hz(measurement, old, elapsed)
        row_data.update(cpu_usage: calc_cpu_usage(href, cpu.total), cpu_baseline_sequence: sweep.sequence - 1,
                        cpu_window_started_monotonic_ns: @previous.started)
      end
      source_deltas(row_data, measurement, old, key, history, sweep, during, mode, elapsed,
                    dataset_changed: previous && row.ct.dataset != previous.ct.dataset)
      row_data
    end

    def gauges(measurement)
      return {} unless measurement

      data = CORE_GAUGES.to_h { |k| [k, numeric(measurement.data[k])] }
      %i[cpu_limit memory_limit].each do |key|
        state = measurement.limit_state(key)
        data[:"#{key}_state"] = state
        data[key] = nil unless state == 'limited'
      end
      data[:nproc] = nil unless data[:nproc].is_a?(Integer)
      data
    end

    def add_gauge_errors(data, measurement)
      errors = data[:errors]
      errors[:loadavg] = 'missing_container_load' unless data[:loadavg]
      %i[memory nproc].each { |k| errors[k] = 'missing_cgroup_value' unless data[k] }
      %i[cpu_limit memory_limit].each do |k|
        next unless data[:"#{k}_state"] == 'unknown'

        errors[k] = measurement&.data&.[](k).nil? ? 'missing_cgroup_value' : 'invalid_limit'
      end
    end

    def cpu_pair_error(measurement, previous, elapsed)
      hz_fields = %i[cpu_user_hz cpu_system_hz]
      return 'required_read_failed' unless measurement
      return 'missing_cgroup_value' unless hz_fields.all? { |k| numeric(measurement.data[k]) }
      return 'initial_baseline' unless previous
      return 'invalid_window' unless elapsed
      return 'missing_cgroup_value' unless hz_fields.all? { |k| numeric(previous.data[k]) }

      measurement.counter_error(previous)
    end

    def source_deltas(data, current, old, key, history, sweep, during, mode, elapsed, dataset_changed: false)
      SOURCES.each do |field|
        value = current&.data&.[](field)
        prior = old&.data&.[](field)
        unstable = during_invalidates_source?(field, key, sweep, during)
        discontinuity = unstable || source_discontinuity?(field, key, sweep, dataset_changed) ||
                        source_replaced?(field, current, old)
        origin_key = [key, field]
        prior_origin = @previous&.origins&.[](origin_key)
        pair = prior_origin && !discontinuity && elapsed&.positive? && delta(value, prior, elapsed)
        origin = (pair && prior_origin) || [history.started, value]
        history.origins[origin_key] = origin unless unstable || value.nil?
        data[field] = if mode == :realtime
                        pair || nil
                      elsif pair
                        delta(value, origin.last, 1)
                      end
        data[:column_windows][field] = (mode == :realtime ? @previous.started : origin.first) if data[field]
      end
    end

    def source_replaced?(field, current, old)
      case field
      when :tx, :rx then current&.netif_sources != old&.netif_sources
      when :zfsio then current&.dataset_source != old&.dataset_source
      else false
      end
    end

    def during_invalidates_source?(field, key, sweep, during)
      case field
      when :tx, :rx
        dirty?(during, :netif, key) || (key.nil? && during.keys.any? { |type, _| type == :netif })
      when :zfsio
        if key
          dirty?(during, :pool, sweep.rows.fetch(key).ct.pool)
        else
          during.keys.any? { |type, _| type == :pool }
        end
      else false
      end
    end

    def source_discontinuity?(field, key, sweep, dataset_changed)
      (field == :zfsio && dataset_changed) || during_invalidates_source?(field, key, sweep, sweep.between) ||
        (key && old_source_changed?(field, key, sweep))
    end

    def old_source_changed?(field, key, sweep)
      return false unless %i[tx rx].include?(field)

      current = sweep.rows.fetch(key).ct.netifs
      old_row = @previous&.rows&.[](key)
      previous = old_row&.ct&.netifs
      current&.map { |i| [i.name, i.veth] } != previous&.map { |i| [i.name, i.veth] }
    end

    def delta(current, previous, elapsed)
      if current.is_a?(Hash)
        return unless previous.is_a?(Hash) && current.keys.sort == previous.keys.sort

        current.to_h do |key, value|
          part = delta(value, previous[key], elapsed)
          return nil if part.nil?

          [key, part]
        end
      else
        current = numeric(current)
        previous = numeric(previous)
        return unless current && previous && current >= previous

        ((current - previous) / elapsed).round
      end
    end

    def project_host(sweep, history, during, mode, rows, memory, cpu)
      node = { memory: memory&.fetch(:used), nproc: sweep.load[:nproc], loadavg: sweep.load[:values], column_windows: {} }
      node[:cpu_usage] = calc_cpu_usage(cpu.total_used, cpu.total) if cpu
      current = sweep.machine.current_measurement
      old = @previous&.machine&.current_measurement
      dataset_changed = history.rows.any? do |key, row|
        previous = @previous&.rows&.[](key)
        previous && (row.ct.dataset != previous.ct.dataset || source_replaced?(:zfsio, row.measurement, previous.measurement))
      end
      source_deltas(node, current, old, nil, history, sweep, during, mode, interval(current, old), dataset_changed:)
      residual = { id: '[host]', pool: nil, init_pid: nil, init_start_time_ticks: nil,
                   cpu_limit: nil, memory_limit: nil, loadavg: node[:loadavg], column_windows: {} }
      roster_compatible = @previous&.closed && sweep.between.keys.none? { |type, _| type == :lifecycle } &&
                          @previous.rows.values.map(&:identity).sort == history.rows.values.map(&:identity).sort
      %i[memory nproc cpu_usage cpu_us tx rx zfsio].each do |field|
        next unless history.closed && node[field] && rows.all? { |row| row[field] }
        next if !%i[memory nproc].include?(field) && !roster_compatible

        window = node[:column_windows][field]
        next if window && rows.any? { |row| row[:column_windows][field] != window }

        residual[field] = rows.reduce(node[field]) { |remaining, row| subtract(remaining, row[field]) }
        residual[:column_windows][field] = window if window
      end
      [node, residual]
    end

    def subtract(total, part)
      if total.is_a?(Hash)
        total.to_h { |key, value| [key, subtract(value, part.fetch(key))] }
      else
        [total - part, 0].max
      end
    end
  end
end
