require 'libosctl'
require 'osctl/oomd/watchdog_state'
require 'osctl/oomd/action_workers'

module OsCtl::Oomd
  # The sole owner of scores and permits in guarded modes.
  class Controller
    DEFAULTS = {
      'enable' => false,
      'state_file' => '/run/rtnl-watchdog.json',
      'max_age_seconds' => 1,
      'latency_threshold_ms' => 1000,
      'sustain_seconds' => 30,
      'pending_seconds' => 30,
      'observation_max_age_seconds' => 5,
      'action_workers' => 2
    }.freeze

    attr_reader :stop_after_seconds, :restart_after_seconds, :episode, :inflight

    RawFrame = Struct.new(:data, :rows, :strict_seed, keyword_init: true)
    STRICT_SEED_REASONS = %w[initial_baseline counter_reset invalid_window invalid_host_cpu_delta].freeze
    DIAGNOSTIC_INTERVAL_NS = 30_000_000_000
    DIAGNOSTIC_BYTES = 2048
    DIAGNOSTIC_FIELDS = %w[run cpu_usage cpu_limit memory memory_limit loadavg nproc].freeze
    DIAGNOSTIC_ERRORS = %w[invalid_limit missing_cgroup_value required_read_failed initial_baseline invalid_window
                           counter_reset invalid_host_cpu_delta monitor_unavailable run_changed invalid_run missing_container_load].freeze

    def self.settings(value)
      config = DEFAULTS.merge(value || {})
      raise ArgumentError, 'rtnl_watchdog.enable must be boolean' unless [true, false].include?(config['enable'])
      unless config['state_file'].is_a?(String) && config['state_file'].start_with?('/')
        raise ArgumentError, 'rtnl_watchdog.state_file must be absolute'
      end

      %w[max_age_seconds observation_max_age_seconds].each do |key|
        value = config[key]
        raise ArgumentError, "invalid rtnl_watchdog.#{key}" unless value.is_a?(Integer) && value > 0
      end
      %w[latency_threshold_ms sustain_seconds pending_seconds].each do |key|
        raise ArgumentError, "invalid rtnl_watchdog.#{key}" unless config[key].is_a?(Integer) && config[key] > 0
      end
      unless config['latency_threshold_ms'].between?(1, 60_000)
        raise ArgumentError, 'rtnl_watchdog.latency_threshold_ms must be 1..60000'
      end

      if config.has_key?('restart_hits')
        raise ArgumentError, 'enabled legacy rtnl_watchdog.restart_hits must migrate to the shared seconds budget' if config['enable']

        warn 'rtnl_watchdog.restart_hits is obsolete and ignored while integration is disabled'
        config.delete('restart_hits')
      end
      unless config['action_workers'].is_a?(Integer) && config['action_workers'].between?(1, 2)
        raise ArgumentError, 'rtnl_watchdog.action_workers must be 1 or 2'
      end

      config
    end

    def initialize(interval:, cpu_percent:, memory_percent:, load_multiplier:, load_top:, restart_after_seconds:, stop_after_seconds:,
                   rtnl_watchdog:, load_enable: true, restart_unknown_expiry_seconds: 30, dry_run: false, host_load: nil, watchdog: nil, workers: nil, executor: nil, evidence: nil, verbose: false)
      @settings = self.class.settings(rtnl_watchdog)
      @interval_ns = (interval * 1_000_000_000).to_i
      @sample_max_age_ns = (@settings.fetch('observation_max_age_seconds') * 1_000_000_000).to_i
      @cpu_percent = cpu_percent
      @memory_percent = memory_percent
      @load_multiplier = load_multiplier
      @load_top = load_top
      raise ArgumentError, 'interval must be a positive integer' unless interval.is_a?(Integer) && interval > 0
      unless restart_unknown_expiry_seconds.is_a?(Integer) && restart_unknown_expiry_seconds > interval + @settings.fetch('observation_max_age_seconds')
        raise ArgumentError, 'restart_unknown_expiry_seconds must exceed interval + observation_max_age_seconds'
      end

      raise ArgumentError, 'load_enable must be boolean' unless [true, false].include?(load_enable)

      [restart_after_seconds, stop_after_seconds].each do |duration|
        raise ArgumentError, 'action budgets must be positive integer seconds' unless duration.is_a?(Integer) && duration > 0
      end
      @load_enable = load_enable
      @restart_after_seconds = restart_after_seconds
      @stop_after_seconds = stop_after_seconds
      @restart_expiry_ns = restart_unknown_expiry_seconds * 1_000_000_000
      @host_load = host_load || HostLoad.new(interval)
      @verbose = verbose
      @cold_loads = []
      @raw_epochs = {}
      @raw_broken = false
      @watchdog = watchdog || WatchdogState.new(path: @settings.fetch('state_file'), max_age_seconds: @settings.fetch('max_age_seconds'),
                                                latency_threshold_ms: @settings.fetch('latency_threshold_ms'),
                                                sustain_seconds: @settings.fetch('sustain_seconds'), pending_seconds: @settings.fetch('pending_seconds'))
      @workers = workers || ActionWorkers.new(size: @settings.fetch('action_workers'), dry_run:, executor:)
      @evidence = evidence || @workers.evidence
      @expiry_tickets = {}
      @paused = false
      @gap = nil
      @records = {}
      @runs = {}
      @inflight = {}
      @export_mutex = Mutex.new
      @export = []
      @status = { notification_drops: 0, notification_failures: 0, unknown_actions: 0 }
      @episode = nil
      @rtnl_generation = 0
      @load_active = nil
      @stopping = false
    end

    def start
      @workers.start
    end

    def stop
      @stopping = true
      @evidence.control('controller_stopping', monotonic_ns: monotonic_ns, message: 'Stopping admissions; draining accepted evidence and actions')
      @workers.stop { |permit, result| complete_action(permit, result) }
    end

    def export
      @export_mutex.synchronize { @export.map(&:clone) }
    end

    def status
      @export_mutex.synchronize { @status.dup }
    end

    # Called independently of the sampler, including while commands are blocked.
    def tick(now_ns: monotonic_ns)
      @observed_episode = @watchdog.episode(now_ns:)
      next_episode = @settings['enable'] ? @observed_episode : nil
      if @last_gate_status != [next_episode, @settings['enable'] ? @watchdog.diagnostic : nil]
        @last_gate_status = [next_episode, @settings['enable'] ? @watchdog.diagnostic : nil]
        @rtnl_generation += 1
        @episode = next_episode
      end
      if @raw && !@raw_broken && now_ns > @raw.data.fetch('sample_completed_monotonic_ns') + @interval_ns + @sample_max_age_ns
        sampling_loss(now_ns, 'observation_deadline')
      end
      @records.each do |key, record|
        before = record.restart_qualified_seconds
        record.expire(now_ns:, expiry_ns: @restart_expiry_ns)
        next unless before > 0 && record.restart_qualified_seconds == 0

        ticket = @expiry_tickets.delete(key)
        @evidence.batch(@evidence.frame('score_expired', pool: key[0], id: key[1],
                                                         monotonic_ns: now_ns, restart_before: before, restart_after: 0), ticket)
      end
      @workers.completions { |permit, result| complete_action(permit, result) }
      publish_export
    end

    def child_started
      @bootstrap = true
      @child_epoch = nil
      @raw_broken = true
      @cold_loads.clear
      break_links
    end

    def invalidate
      @bootstrap = false
      sampling_loss(monotonic_ns, 'invalid_or_broken_observation')
      publish_export
      false
    end

    def observe(data, now_ns: nil)
      processing_started = monotonic_ns
      now_ns ||= processing_started
      tick(now_ns:)
      ticket = @evidence.reserve(Evidence::SAMPLE_RECORDS, Evidence::SAMPLE_BYTES) if @evidence.control_ready?
      unless ticket
        pause_evidence(data, now_ns, 'logging_pressure')
        return false
      end
      snapshot = [@records, @runs]
      old_cold_loads = @cold_loads.dup
      committed = false
      additions = nil
      @records = @records.transform_values(&:clone)
      @runs = @runs.dup
      @sample_rows = []
      @qualifications = {}
      @actions = []
      @staged_loads = []
      @staged_diagnostic = nil
      @sample_median = @sample_history_count = nil
      bootstrap = @bootstrap
      @bootstrap = false
      begin
        accepted = observe_packet(data, now_ns, processing_started, bootstrap:)
        unless @packet_accepted
          @records, @runs = snapshot
          return false
        end
        records = sample_records(data, now_ns)
        raise Evidence::Oversize, 'sample exceeds batch limit' if records.size > Evidence::SAMPLE_RECORDS

        additions = reserve_expiries
        unless additions
          @records, @runs = snapshot
          pause_evidence(data, now_ns, 'expiry_reservation_pressure')
          return false
        end
        resume_evidence(data, now_ns) if @paused || @gap
        @evidence.batch(records, ticket)
        @evidence.release(ticket)
        @expiry_tickets.merge!(additions)
        committed = true
        @expiry_tickets.each_key do |key|
          @evidence.release(@expiry_tickets.delete(key)) unless @records[key]&.restart_qualified_seconds.to_f > 0
        end
        @staged_loads.each { |load| @host_load << load }
        @diagnostic_epoch, @diagnostic_at, @diagnostic_cursor = @staged_diagnostic if @staged_diagnostic
        @actions.each { |args, opts| dispatch(*args, **opts) }
        publish_export
        accepted
      rescue Evidence::Oversize
        @records, @runs = snapshot
        pause_evidence(data, now_ns, 'sample_oversize')
        false
      ensure
        unless committed
          additions&.each_value { |reserved| @evidence.release(reserved) }
          @cold_loads = old_cold_loads
          break_links if @raw_broken
          publish_export
        end
        @packet_accepted = false
        @evidence.release(ticket)
        @sample_rows = @actions = nil
      end
    end

    def mailbox_gap(first:, last:, count:, first_epoch: nil, last_epoch: nil)
      @gap ||= { first_sequence: first, last_sequence: last, omitted_count: 0 }
      @gap[:first_epoch] ||= first_epoch
      @gap[:last_epoch] = last_epoch
      @gap[:last_sequence] = last
      @gap[:omitted_count] += count
      invalidate
    end

    protected

    def prepare_host_load(data, full:)
      load = data['loadavg']&.first
      return @load_enable ? nil : false unless Eligibility::Partial.reading?(load)

      if @host_load.established? || (full && @cold_loads.empty?)
        @cold_loads.clear
        @staged_loads = [load]
        @sample_median = @host_load.median_with(load) || load
        @sample_history_count = [@host_load.count + 1, 86_400 / (@interval_ns / 1_000_000_000)].min if @host_load.respond_to?(:count)
      else
        @sample_median = @host_load.cold_median_with(@cold_loads, load)
        @sample_history_count = @cold_loads.size
        if @sample_median
          @staged_loads = @cold_loads.dup
          @cold_loads.clear
        end
      end
      load_gate(load, @sample_median)
    end

    def observe_packet(data, now, processing_started, bootstrap:)
      return invalidate unless valid_header?(data, now)

      epoch = data['epoch']
      previous = @raw
      prior = previous&.data
      new_epoch = @child_epoch.nil?
      return invalidate if new_epoch && @raw_epochs.has_key?(epoch)
      return invalidate unless new_epoch || @child_epoch == epoch

      @child_epoch = epoch
      @raw_epochs[epoch] = true
      same_epoch = prior && prior['epoch'] == epoch
      return false if prior.eql?(data)
      return invalidate if same_epoch && data['sequence'] <= prior['sequence']
      return invalidate if prior && data['sample_started_monotonic_ns'] <= prior['sample_completed_monotonic_ns']

      rows, coherent_seed = packet_rows(data)
      return invalidate unless rows

      if same_epoch && data['sequence'] > prior['sequence'] + 1 && !@gap
        @gap = { first_epoch: epoch, last_epoch: epoch, first_sequence: prior['sequence'] + 1,
                 last_sequence: data['sequence'] - 1, omitted_count: data['sequence'] - prior['sequence'] - 1 }
      end
      adjacent = same_epoch && data['sequence'] == prior['sequence'] + 1
      if adjacent && data['previous_sample_started_monotonic_ns'] != prior['sample_started_monotonic_ns']
        return invalidate
      end

      linked = adjacent && !@raw_broken
      break_links unless linked
      full = data['complete'] && ((new_epoch && bootstrap) || (linked && previous.strict_seed && same_runs?(rows, previous.rows)))
      seed = coherent_seed || data['complete']
      @packet_accepted = true
      @raw = RawFrame.new(data:, rows:, strict_seed: seed)
      @raw_broken = false
      gate = prepare_host_load(data, full:)
      @load_active = gate
      unless full || linked
        roster = rows.values + [data.fetch('containers').last]
        ranked = Eligibility.rank(roster).take([@load_top, 0].max) if roster.all? { |row| row['loadavg'] }
        rows.each do |key, row|
          hit = Eligibility::Partial.decidable?(row) && matching_cpu_window?(row, data) ? ranked_hit?(row, roster, ranked) : nil
          @qualifications[key] = hit
          before = @records[key]
          if hit || before&.restart_qualified_seconds.to_f > 0
            select_row(evidence_row(key, row, hit, before&.restart_qualified_seconds || 0, before&.stop_qualified_seconds || 0, 0, nil, nil, 'unlinked_baseline'))
          end
        end
        return false
      end

      score_rows(data, rows, previous, gate, now, processing_started, linked:)
    end

    def packet_rows(data)
      rows = Eligibility::Partial.index(data)
      return unless rows

      memory = data['memory']
      core = data['inventory_complete'] && data['loadavg'] && memory.is_a?(Hash) && Eligibility::Partial.reading?(memory['used']) &&
             rows.values.all? { |row| Eligibility::Partial.current_core?(row) }
      if data['complete']
        cpu = data['cpu']
        return unless core && cpu.is_a?(Hash) && cpu.any? && cpu.values.all? { |value| Eligibility::Partial.reading?(value) } &&
                      complete_partial_rows?(data, rows)
      end
      [rows, core && strict_seed?(data, rows)]
    end

    def valid_header?(data, now)
      return false unless data.is_a?(Hash) && 2.eql?(data['top_schema']) && !data.has_key?('observation')
      return false unless data['epoch'].is_a?(String) && data['epoch'].bytesize.between?(1, 95) && positive?(data['sequence'])
      return false unless data['collectors'].is_a?(Hash) && %w[netif zfs iostat].all? { |key| data['collectors'][key] == false }

      started = data['sample_started_monotonic_ns']
      completed = data['sample_completed_monotonic_ns']
      return false unless positive?(started) && positive?(completed) && started <= completed && completed <= now
      return false if completed - started > @sample_max_age_ns || now - completed > @sample_max_age_ns
      return false unless completed.eql?(data['measurement_window_completed_monotonic_ns'])
      return false unless data.has_key?('invalid_reason') && data.has_key?('measurement_window_started_monotonic_ns')

      window = data['measurement_window_started_monotonic_ns']
      return false unless data.has_key?('previous_sample_started_monotonic_ns')

      previous = data['previous_sample_started_monotonic_ns']
      return false unless data['sequence'] == 1 ? previous.nil? : positive?(previous) && previous < started

      if data['complete'] == true
        data['invalid_reason'].nil? && positive?(window) && window == previous && cpu_window?(data)
      else
        data['complete'] == false && Eligibility::Partial.string?(data['invalid_reason']) && window.nil?
      end
    end

    def cpu_window?(data)
      previous = data['previous_sample_started_monotonic_ns']
      previous && data['sample_completed_monotonic_ns'] - previous <= @interval_ns + @sample_max_age_ns
    end

    def matching_cpu_window?(row, data)
      cpu_window?(data) && positive?(row['cpu_baseline_sequence']) && positive?(row['cpu_window_started_monotonic_ns']) &&
        row['cpu_baseline_sequence'] == data['sequence'] - 1 &&
        row['cpu_window_started_monotonic_ns'] == data['previous_sample_started_monotonic_ns']
    end

    def strict_seed?(data, rows)
      STRICT_SEED_REASONS.include?(data['invalid_reason']) && rows.values.all? { |row| cpu_seed?(data, row) }
    end

    def cpu_seed?(data, row)
      return false unless row

      return matching_cpu_window?(row, data) if row['cpu_usage']

      STRICT_SEED_REASONS.include?(row['errors']['cpu_usage'])
    end

    def complete_partial_rows?(data, rows)
      rows.values.all? do |row|
        Eligibility::Partial.usable_cpu?(row) && Eligibility::Partial.finite_percent?(row['memory'], row['memory_limit']) &&
          matching_cpu_window?(row, data)
      end
    end

    def same_runs?(rows, previous)
      rows.size == previous.size && rows.all? { |key, row| previous[key] && run_identity(row) == run_identity(previous[key]) }
    end

    def score_rows(data, rows, previous, gate, now, processing_started, linked:)
      @load_active = gate
      # Freeze the competing population for this observation. A grant takes
      # its target out of the ranking starting with the next observation.
      candidates = rows.reject { |key, row| @inflight.has_key?(key) || !row['run_verified'] }
      roster = candidates.values + [data.fetch('containers').last]
      ranked = Eligibility.rank(roster).take([@load_top, 0].max) if roster.all? { |row| row['loadavg'] }
      rows.each do |key, row|
        record = (@records[key] ||= ContainerScore.new(*key))
        before = [record.restart_qualified_seconds, record.stop_qualified_seconds]
        update_run(record, key, row)
        unless candidates.has_key?(key)
          select_row(evidence_row(key, row, nil, *before, 0, gate, nil, @inflight.has_key?(key) ? 'inflight' : 'unverified_run')) if before[0] > 0 || before != [record.restart_qualified_seconds, record.stop_qualified_seconds]
          next
        end

        if !linked || !previous || !usable_pair?(data, row, previous, key)
          record.break_link
        end
        hit = Eligibility::Partial.decidable?(row) && matching_cpu_window?(row, data) ? ranked_hit?(row, roster, ranked) : nil
        @qualifications[key] = hit
        combined = gate_token(gate)
        scored_generation = @rtnl_generation
        delta = record.observe(now_ns: data.fetch('sample_completed_monotonic_ns'), qualification: hit,
                               gate_token: combined, load_gate: gate, linked:, interval_ns: @interval_ns)
        rank = ranked ? ranked.index(row)&.+(1) : Eligibility.rank_proof(row, roster, nil, @load_top)
        if hit || before[0] > 0 || record.restart_qualified_seconds > 0 || before != [record.restart_qualified_seconds, record.stop_qualified_seconds]
          reason = if !linked || !previous || !usable_pair?(data, row, previous, key)
                     'unlinked_or_incomplete'
                   elsif combined.nil?
                     'unknown_gate'
                   elsif combined == false
                     'inactive_gate'
                   elsif !@workers.available?
                     'worker_unavailable'
                   else
                     'insufficient_time_or_pending_fresh_admission'
                   end
          select_row(evidence_row(key, row, hit, *before, delta, gate, rank, reason))
        end
        next unless hit

        action = if gate && record.stop_qualified_seconds >= stop_after_seconds
                   :stop
                 elsif combined && record.restart_qualified_seconds >= restart_after_seconds
                   :restart
                 end
        @actions << [[row, key, action, now, processing_started], { scored_generation: }] if action
      end
      # Disappearance invalidates restart evidence; stop history retains the
      # ordinary success/reset semantics across restarts and inventory sweeps.
      (@records.keys - rows.keys).each do |key|
        record = @records.fetch(key)
        before = [record.restart_qualified_seconds, record.stop_qualified_seconds]
        record.reset_restart
        select_row({ pool: key[0], id: key[1], reason: 'disappeared', restart_before: before[0], restart_after: 0, stop_before: before[1], stop_after: before[1] }) if before[0] > 0
        next if @inflight.has_key?(key) || record.stop_qualified_seconds > 0

        @records.delete(key)
        @runs.delete(key)
      end
      true
    end

    def ranked_hit?(row, roster, ranked)
      if ranked
        return Eligibility.hit?(row, ranked, memory_percent: @memory_percent, cpu_percent: @cpu_percent, load_top: @load_top)
      end

      rank = Eligibility.rank_proof(row, roster, nil, @load_top)
      rank && Eligibility.resource_hit?(row, memory_percent: @memory_percent, cpu_percent: @cpu_percent)
    end

    def usable_pair?(data, row, previous, key)
      prior = previous.rows[key]
      run_identity(row) == run_identity(prior) && cpu_seed?(previous.data, prior) &&
        Eligibility::Partial.decidable?(row) && matching_cpu_window?(row, data)
    end

    def load_gate(load, median)
      return false unless @load_enable
      return if median.nil?

      threshold = median * @load_multiplier
      load >= threshold if Eligibility::Partial.reading?(threshold)
    end

    def gate_token(gate)
      return false if gate == false && !@episode && (!@settings['enable'] || @watchdog&.diagnostic.nil?)
      return nil unless gate || @episode

      { load: gate == true, rtnl: @episode && [@episode, @rtnl_generation] }
    end

    def monotonic_ns
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    end

    def positive?(value)
      value.is_a?(Integer) && value > 0
    end

    def run_identity(row)
      Eligibility::Partial.run(row)
    end

    def update_run(record, key, row)
      identity = run_identity(row)
      record.reset_restart if @runs[key] != identity
      @runs[key] = identity
    end

    def dispatch(ct, key, action, now, processing_started, scored_generation:)
      # Refresh RTNL at grant, retaining this frame's single-inclusion load
      # median: its current load has already been committed to host history.
      tick(now_ns: now + (monotonic_ns - processing_started))
      # No deferred permit queue: recheck this exact current frame/run at grant.
      frame = @raw.data
      return if @stopping || @inflight.has_key?(key) || @raw_broken
      return unless @raw.rows[key].equal?(ct) && @runs[key] == run_identity(ct)

      record = @records.fetch(key)
      gate = load_gate(frame['loadavg']&.first, @sample_median)
      if action == :stop
        return unless gate && record.stop_qualified_seconds >= stop_after_seconds
      else
        return unless gate_token(gate) && record.restart_qualified_seconds >= restart_after_seconds
        return if !gate && scored_generation != @rtnl_generation
        return if gate && record.stop_qualified_seconds >= stop_after_seconds
      end

      run = ct.values_at('init_pid', 'init_start_time_ticks')
      deadline = frame.fetch('sample_completed_monotonic_ns') + @sample_max_age_ns
      permit = { pool: key[0], id: key[1], run:, action:, epoch: frame['epoch'], sequence: frame['sequence'],
                 watchdog_episode: @episode, time: Time.now.to_i }
      # This is an enqueue deadline, not a deadline on the daemon's action.
      return if now + (monotonic_ns - processing_started) > deadline

      granted = @workers.dispatch(permit) do
        grant_now = now + (monotonic_ns - processing_started)
        tick(now_ns: grant_now)
        grant_now <= deadline && !@raw_broken && @runs[key] == run_identity(ct) &&
          (if action == :stop
             gate && record.stop_qualified_seconds >= stop_after_seconds
           else
             gate_token(gate) && record.restart_qualified_seconds >= restart_after_seconds && (gate || scored_generation == @rtnl_generation)
           end)
      end
      return unless granted

      @inflight[key] = permit
      @records.fetch(key).reset_restart
      @evidence.release(@expiry_tickets.delete(key))
    end

    def complete_action(permit, result)
      key = [permit.fetch(:pool), permit.fetch(:id)]
      return unless @inflight[key].equal?(permit)

      if result == :unknown
        permit[:unknown] = true
      else
        @inflight.delete(key)
        record = @records[key]
        record&.reset_restart
        record&.reset_stop if %i[success simulated].include?(result) && permit[:action] == :stop
      end
      @evidence.release(@expiry_tickets.delete(key)) unless result == :unknown
    end

    def select_row(row)
      raise Evidence::Oversize, 'sample selection exceeds bounded batch' if @sample_rows.size >= Evidence::SAMPLE_RECORDS - 3

      @sample_rows << row
    end

    def evidence_row(key, row, hit, restart_before, stop_before, delta, gate, rank, reason)
      record = @records[key]
      { pool: key[0], id: key[1], message: "#{key.join(':')} qualified=#{hit.inspect} covered_delta=#{delta} restart_seconds=#{record&.restart_qualified_seconds || 0}", run: run_identity(row), run_verified: row['run_verified'],
        cpu: row['cpu_usage'], cpu_limit: row['cpu_limit'], cpu_limit_state: row['cpu_limit_state'],
        memory: row['memory'], memory_limit: row['memory_limit'], memory_limit_state: row['memory_limit_state'],
        loadavg: row['loadavg'], rank:, qualified: hit, errors: row['errors'],
        resource_eligible: Eligibility::Partial.decidable?(row) ? Eligibility.resource_hit?(row, memory_percent: @memory_percent, cpu_percent: @cpu_percent) : nil,
        linked: !record&.anchor_ns.nil?, load_gate: gate, rtnl_gate: @episode, covered_delta_seconds: delta,
        restart_before:, restart_after: record&.restart_qualified_seconds || 0,
        stop_before:, stop_after: record&.stop_qualified_seconds || 0, reason: }
    end

    def sample_records(data, now)
      identity = { sample_epoch: data['epoch'], sample_sequence: data['sequence'] }
      median = @sample_history_count.nil? ? @host_load.median : @sample_median
      threshold = median && (median * @load_multiplier)
      threshold = nil unless threshold&.finite?
      ratio = data['loadavg'] && threshold && threshold > 0 ? data['loadavg'][0] / threshold.to_f : nil
      ratio = nil unless ratio&.finite?
      host = { message: "load gate=#{@load_active.inspect} RTNL policy=#{@episode.inspect} observed=#{@observed_episode.inspect}", monotonic_ns: now, acquisition_started_ns: data['sample_started_monotonic_ns'],
               acquisition_completed_ns: data['sample_completed_monotonic_ns'],
               observation_age_seconds: (now - data['sample_completed_monotonic_ns']) / 1e9,
               complete: data['complete'], invalid_reason: data['invalid_reason'], inventory_complete: data['inventory_complete'],
               population: @raw.rows.size, selected: @sample_rows.size, selection: @sample_rows.empty? ? 'none' : 'subset',
               qualifier_count: @qualifications.values.count(true),
               unknown_count: @raw.rows.keys.count { |key| @qualifications[key].nil? },
               ineligible_count: @qualifications.values.count(false),
               count_semantics: 'qualifier/unknown/ineligible partition current population; selected/excluded describe row selection',
               excluded_count: @raw.rows.size - @sample_rows.count { |row| @raw.rows.has_key?([row[:pool], row[:id]]) },
               load1: data['loadavg']&.first, history_median: median,
               history_count: @sample_history_count || (@host_load.respond_to?(:count) ? @host_load.count : nil),
               load_threshold: threshold, load_threshold_ratio: ratio, ratio_reason: ratio ? nil : 'unknown_or_zero_threshold',
               load_enable: @load_enable, load_gate: @load_active, rtnl_enable: @settings['enable'],
               rtnl_observed_episode: @observed_episode, rtnl_policy_episode: @episode,
               rtnl_diagnostic: @watchdog.diagnostic, rtnl_details: @watchdog.details,
               rtnl_frame: @watchdog.respond_to?(:observation) ? @watchdog.observation : nil,
               policy: @settings.merge('interval_seconds' => @interval_ns / 1_000_000_000,
                                       'load_multiplier' => @load_multiplier, 'load_enable' => @load_enable, 'cpu_percent' => @cpu_percent, 'memory_percent' => @memory_percent, 'load_top' => @load_top, 'restart_after_seconds' => restart_after_seconds,
                                       'stop_after_seconds' => stop_after_seconds, 'restart_unknown_expiry_seconds' => @restart_expiry_ns / 1_000_000_000) }
      inventory = inventory_diagnostic(data, now)
      host[:inventory_observation] = inventory
      deferred_inventory = inventory if diagnostic_bytes('host', identity.merge(host)) > Evidence::LINE_BYTES
      host.delete(:inventory_observation) if deferred_inventory
      body = @evidence.frame('host', identity.merge(host))
      @sample_rows.each do |row|
        body.concat(@evidence.frame('container', identity.merge(row)))
        raise Evidence::Oversize, 'sample population exceeds bounded batch' if body.size + 2 > Evidence::SAMPLE_RECORDS
      end
      page, disposition = unknown_diagnostic(data, identity, body, deferred_inventory)
      disposition[:inventory_status] = inventory[:status]
      body.concat(page) if page
      counts = { selected_records: @sample_rows.size, expected_lines: body.size + 2, unknown_diagnostic: disposition }
      @evidence.frame('sample_begin', identity.merge(counts)) + body + @evidence.frame('sample_end', identity.merge(counts).merge(emitted_lines: body.size + 2))
    end

    def diagnostic_integer?(value)
      value.is_a?(Integer) && value.between?(0, 18_446_744_073_709_551_615)
    end

    def inventory_completion(value, now)
      return if value.nil?
      return false unless value.is_a?(Hash) && %w[id started_monotonic_ns completed_monotonic_ns duration_ns].all? { |key| diagnostic_integer?(value[key]) }
      return false unless value['id'] > 0 && value['started_monotonic_ns'] > 0 &&
                          value['started_monotonic_ns'] <= value['completed_monotonic_ns'] && value['completed_monotonic_ns'] <= now &&
                          value['duration_ns'] == value['completed_monotonic_ns'] - value['started_monotonic_ns'] &&
                          %w[success invalid_inventory required_read_failed].include?(value['result'])

      value.slice('id', 'started_monotonic_ns', 'completed_monotonic_ns', 'duration_ns', 'result')
    end

    def inventory_diagnostic(data, received_at)
      return { status: 'missing' } unless data.has_key?('inventory_observation')

      value = data['inventory_observation']
      return { status: 'malformed' } unless value.is_a?(Hash) && value['version'].is_a?(Integer)
      return { status: 'unsupported' } unless value['version'] == 1
      return { status: 'malformed' } unless %w[request last_completion last_success].all? { |key| value.has_key?(key) }

      now = value['observed_monotonic_ns']
      return { status: 'malformed' } unless diagnostic_integer?(now) && now.between?(data['sample_started_monotonic_ns'], received_at) && value['epoch'] == data['epoch']

      request = value['request']
      unless request.nil?
        return { status: 'malformed' } unless request.is_a?(Hash) && positive?(request['id']) && diagnostic_integer?(request['id']) &&
                                              positive?(request['started_monotonic_ns']) && request['started_monotonic_ns'] <= now &&
                                              %w[pending completed_unconsumed].include?(request['status'])

        request = request.slice('id', 'started_monotonic_ns', 'status')
      end
      completion = inventory_completion(value['last_completion'], now)
      success = inventory_completion(value['last_success'], now)
      if completion == false || success == false || (success && (success['result'] != 'success' || !completion || success['id'] > completion['id']))
        return { status: 'malformed' }
      end

      { status: 'available', version: 1, epoch: value['epoch'], observed_monotonic_ns: now, request:,
        last_completion: completion, last_success: success }
    end

    # Account for the envelope and final event sequence before generating an
    # optional record. Diagnostic pages never use mandatory fragmentation.
    def diagnostic_bytes(type, fields)
      JSON.generate({ evidence_schema: 1, process_epoch: @evidence.epoch, type: }.merge(fields)).bytesize + 160
    end

    def unknown_diagnostic(data, identity, body, inventory)
      keys = @raw.rows.keys.select { |key| @qualifications[key].nil? }.sort
      disposition = { unknown_total: keys.size, status: 'none', considered: 0, reported: 0, unrepresentable: 0,
                      wrapped: false, inventory_detail: inventory ? 'deferred' : 'host' }
      return [nil, disposition] if keys.empty? && !inventory

      now = data.fetch('sample_completed_monotonic_ns')
      same_epoch = @diagnostic_epoch == data['epoch']
      if same_epoch && @diagnostic_at && now - @diagnostic_at < DIAGNOSTIC_INTERVAL_NS
        return [nil, disposition.merge(status: 'not_due')]
      end

      bytes = body.sum { |record| JSON.generate(record).bytesize + 160 } + (2 * Evidence::LINE_BYTES)
      if body.size + 3 > Evidence::SAMPLE_RECORDS || bytes + DIAGNOSTIC_BYTES > Evidence::SAMPLE_BYTES
        return [nil, disposition.merge(status: 'deferred')]
      end

      cursor = @diagnostic_cursor if same_epoch
      start = cursor && keys.bsearch_index { |key| (key <=> cursor) > 0 }
      start = 0 unless cursor
      wrapped = start.nil? ? !keys.empty? : false
      start ||= 0
      candidates = keys.rotate(start).take(4)
      wrapped ||= start + candidates.size > keys.size
      fields = identity.merge(unknown_total: keys.size, considered: candidates.size, reported: 4, unrepresentable: 4, wrapped:)
      fields[:inventory_observation] = inventory if inventory
      budget = (DIAGNOSTIC_BYTES - diagnostic_bytes('unknown_targets', fields.merge(entries: [])) - 8) / [candidates.size, 1].max
      return [nil, disposition.merge(status: 'deferred')] if budget < 160

      positions = @raw.rows.keys.each_with_index.to_h
      entries = candidates.map { |key| unknown_entry(key, positions.fetch(key), data, budget) }
      reported = entries.count { |entry| entry.has_key?(:id) }
      disposition.update(status: 'emitted', considered: entries.size, reported:, unrepresentable: entries.size - reported,
                         wrapped:, inventory_detail: inventory ? 'page' : 'host')
      fields.update(entries:, reported:, unrepresentable: entries.size - reported)
      @staged_diagnostic = [data['epoch'], now, candidates.last || cursor]
      [@evidence.frame('unknown_targets', fields), disposition]
    end

    def unknown_entry(key, position, data, budget)
      row = @raw.rows.fetch(key)
      errors = DIAGNOSTIC_FIELDS.filter_map do |field|
        reason = row['errors'][field]
        next unless reason

        [field, DIAGNOSTIC_ERRORS.include?(reason) ? reason : 'unrecognized_error', reason.bytesize]
      end.take(2)
      reasons = []
      reasons << 'run_unverified' unless row['run_verified']
      reasons << 'resources_unknown' unless Eligibility::Partial.decidable?(row)
      reasons << 'cpu_window_unknown' unless matching_cpu_window?(row, data)
      reasons << (@inflight.has_key?(key) ? 'inflight' : 'rank_unknown') if reasons.empty?
      entry = { row_reference: position, pool: key[0], id: key[1], run_verified: row['run_verified'],
                cpu_limit_state: row['cpu_limit_state'], memory_limit_state: row['memory_limit_state'],
                errors:, errors_total: row['errors'].size, reasons: }
      return entry if key.sum(&:bytesize) <= budget && JSON.generate(entry).bytesize <= budget

      { row_reference: position, unrepresented: 'entry_exceeds_page_budget', field_bytes: { pool: key[0].bytesize, id: key[1].bytesize } }
    end

    def reserve_expiries
      additions = {}
      @records.each do |key, record|
        next unless record.restart_qualified_seconds > 0 && !@expiry_tickets.has_key?(key)

        count = @evidence.frame('score_expired', pool: key[0], id: key[1], monotonic_ns: 18_446_744_073_709_551_615,
                                                 restart_before: record.restart_qualified_seconds, restart_after: 0).size + 1
        ticket = @evidence.reserve(count)
        unless ticket
          additions.each_value { |reserved| @evidence.release(reserved) }
          return nil
        end
        additions[key] = ticket
      end
      additions
    end

    def sampling_loss(now, reason)
      unless @paused
        @evidence.control('evidence_paused', monotonic_ns: now, reason:)
        @paused = true
      end
      @gap ||= { started_ns: now, first_sequence: nil, last_sequence: nil, omitted_count: 0 }
      @raw_broken = true
      break_links
    end

    def pause_evidence(data, now, reason)
      unless @paused
        @evidence.control('evidence_paused', monotonic_ns: now, reason:)
        @paused = true
      end
      sequence = data.is_a?(Hash) ? data['sequence'] : nil
      @gap ||= { started_ns: now, first_sequence: sequence, last_sequence: sequence, omitted_count: 0 }
      @gap[:last_sequence] = sequence
      @gap[:omitted_count] += 1
      @raw_broken = true
      break_links
      publish_export
    end

    def resume_evidence(data, now)
      @evidence.control('evidence_resumed', (@gap || {}).merge(monotonic_ns: now, sample_epoch: data['epoch'], resumed_sequence: data['sequence']))
      @paused = false
      @gap = nil
    end

    def break_links
      @records.each_value(&:break_link)
    end

    def publish_export
      values = @records.values.map(&:clone)
      status = {
        notification_drops: @workers.notification_drops,
        notification_failures: @workers.notification_failures,
        unknown_actions: @inflight.values.count { |permit| permit[:unknown] },
        evidence_paused: @paused ? 1 : 0
      }.merge(@evidence.status)
      @export_mutex.synchronize do
        @export = values
        @status = status
      end
    end
  end
end
