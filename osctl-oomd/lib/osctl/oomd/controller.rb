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
                   rtnl_watchdog:, load_enable: true, restart_unknown_expiry_seconds: 30, dry_run: false, host_load: nil, watchdog: nil, workers: nil, executor: nil, verbose: false)
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
      if @settings.fetch('enable')
        @watchdog = watchdog || WatchdogState.new(path: @settings.fetch('state_file'), max_age_seconds: @settings.fetch('max_age_seconds'),
                                                  latency_threshold_ms: @settings.fetch('latency_threshold_ms'),
                                                  sustain_seconds: @settings.fetch('sustain_seconds'), pending_seconds: @settings.fetch('pending_seconds'))
      end
      @workers = workers || ActionWorkers.new(size: @settings.fetch('action_workers'), dry_run:, executor:)
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
      @workers.stop
    end

    def export
      @export_mutex.synchronize { @export.map(&:clone) }
    end

    def status
      @export_mutex.synchronize { @status.dup }
    end

    # Called independently of the sampler, including while commands are blocked.
    def tick(now_ns: monotonic_ns)
      next_episode = @watchdog&.episode(now_ns:)
      if @last_gate_status != [next_episode, @watchdog&.diagnostic]
        @last_gate_status = [next_episode, @watchdog&.diagnostic]
        @workers.publish(type: :log, level: :info, message: "RTNL gate=#{next_episode.inspect} diagnostic=#{@watchdog&.diagnostic.inspect} details=#{@watchdog&.details.inspect}")
        @rtnl_generation += 1
        @episode = next_episode
      end
      if @raw && now_ns > @raw.data.fetch('sample_completed_monotonic_ns') + @interval_ns + @sample_max_age_ns
        @raw_broken = true
        break_links
      end
      @records.each_value { |record| record.expire(now_ns:, expiry_ns: @restart_expiry_ns) }
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
      @raw_broken = true
      break_links
      publish_export
      false
    end

    def observe(data, now_ns: nil)
      processing_started = monotonic_ns
      now_ns ||= processing_started
      tick(now_ns:)
      bootstrap = @bootstrap
      @bootstrap = false
      observe_packet(data, now_ns, processing_started, bootstrap:)
    end

    protected

    def update_host_load(data)
      load = data.fetch('loadavg').fetch(0)
      @cold_loads.clear
      @host_load << load
      gate = load_gate(load, @host_load.median)
      if @verbose
        @workers.publish(type: :log, level: :debug, message: "Load=#{load}, median=#{@host_load.median}, threshold=#{@host_load.median * @load_multiplier}")
        @workers.publish(type: :log, level: :debug, message: gate ? 'OOMd active' : 'OOMd inactive')
      end
      gate
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

      adjacent = same_epoch && data['sequence'] == prior['sequence'] + 1
      if adjacent && data['previous_sample_started_monotonic_ns'] != prior['sample_started_monotonic_ns']
        return invalidate
      end

      linked = adjacent && !@raw_broken
      break_links unless linked
      full = data['complete'] && ((new_epoch && bootstrap) || (linked && previous.strict_seed && same_runs?(rows, previous.rows)))
      seed = coherent_seed || data['complete']
      @raw = RawFrame.new(data:, rows:, strict_seed: seed)
      @raw_broken = false
      @cold_loads.clear if seed
      if full
        gate = update_host_load(data)
      else
        cold_gate = update_cold_history(data) unless seed
        unless linked
          publish_export
          return false
        end
        gate = partial_load_gate(data)
        gate = cold_gate if gate.nil?
      end

      score_rows(data, rows, previous, gate, now, processing_started, cold_gate, linked:, full:)
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

    def score_rows(data, rows, previous, gate, now, processing_started, cold_gate, linked:, full:)
      if gate != @load_active
        @load_active = gate
        @workers.publish(type: :log, level: :info,
                         message: "load gate=#{gate.inspect} load=#{data['loadavg']&.first.inspect} " \
                                  "median=#{@host_load.median} multiplier=#{@load_multiplier} sample_epoch=#{data['epoch']} sequence=#{data['sequence']}")
      end
      # Freeze the competing population for this observation. A grant takes
      # its target out of the ranking starting with the next observation.
      candidates = rows.reject { |key, row| @inflight.has_key?(key) || !row['run_verified'] }
      roster = candidates.values + [data.fetch('containers').last]
      ranked = Eligibility.rank(roster).take([@load_top, 0].max) if roster.all? { |row| row['loadavg'] }
      rows.each do |key, row|
        record = (@records[key] ||= ContainerScore.new(*key))
        update_run(record, key, row)
        next unless candidates.has_key?(key)

        if !linked || !previous || !usable_pair?(data, row, previous, key)
          record.break_link
        end
        hit = Eligibility::Partial.decidable?(row) && matching_cpu_window?(row, data) ? ranked_hit?(row, roster, ranked) : nil
        combined = gate_token(gate)
        scored_generation = @rtnl_generation
        before = [record.restart_qualified_seconds, record.stop_qualified_seconds]
        delta = record.observe(now_ns: data.fetch('sample_completed_monotonic_ns'), qualification: hit,
                               gate_token: combined, load_gate: gate, linked:, interval_ns: @interval_ns)
        if before != [record.restart_qualified_seconds, record.stop_qualified_seconds] || @verbose
          rank = ranked ? ranked.index(row)&.+(1) : Eligibility.rank_proof(row, roster, nil, @load_top)
          @workers.publish(type: :log, level: :info,
                           message: "#{key.join(':')} qualified=#{hit.inspect} load_gate=#{gate.inspect} rtnl_gate=#{@episode.inspect} " \
                                    "cpu=#{row['cpu_usage'].inspect} cpu_limit=#{row['cpu_limit'].inspect} memory=#{row['memory'].inspect} " \
                                    "memory_limit=#{row['memory_limit'].inspect} rank=#{rank.inspect} covered_delta=#{delta} " \
                                    "restart_seconds=#{record.restart_qualified_seconds}/#{restart_after_seconds} " \
                                    "stop_seconds=#{record.stop_qualified_seconds}/#{stop_after_seconds} " \
                                    "sample_epoch=#{data['epoch']} sequence=#{data['sequence']} run=#{@runs[key].inspect}")
        end
        next unless hit

        action = if gate && record.stop_qualified_seconds >= stop_after_seconds
                   :stop
                 elsif combined && record.restart_qualified_seconds >= restart_after_seconds
                   :restart
                 end
        dispatch(row, key, action, now, processing_started, gate:, partial: !full, cold_gate:, scored_generation:) if action
      end
      # Disappearance invalidates restart evidence; stop history retains the
      # ordinary success/reset semantics across restarts and inventory sweeps.
      (@records.keys - rows.keys).each do |key|
        record = @records.fetch(key)
        record.reset_restart
        next if @inflight.has_key?(key) || record.stop_qualified_seconds > 0

        @records.delete(key)
        @runs.delete(key)
      end
      publish_export
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

    def update_cold_history(data)
      if @host_load.established?
        @cold_loads.clear
        return
      end
      load = data['loadavg']&.first
      load_gate(load, @host_load.cold_median_with(@cold_loads, load)) if load
    end

    def partial_load_gate(data)
      return false unless @load_enable

      load = data['loadavg']&.first
      load_gate(load, @host_load.median_with(load)) if load
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

    def dispatch(ct, key, action, now, processing_started, gate:, partial:, cold_gate:, scored_generation:)
      # Re-read the independent host gate and effective threshold at grant,
      # even if scoring or another candidate took time since the first tick.
      tick(now_ns: now + (monotonic_ns - processing_started))
      # No deferred permit queue: recheck this exact current frame/run at grant.
      frame = @raw.data
      return if @stopping || @inflight.has_key?(key) || @raw_broken
      return unless @raw.rows[key].equal?(ct) && @runs[key] == run_identity(ct)

      record = @records.fetch(key)
      if partial
        gate = partial_load_gate(frame)
        gate = cold_gate if gate.nil?
      end
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
      return unless @workers.dispatch(permit)

      @inflight[key] = permit
      @records.fetch(key).reset_restart
      @workers.publish(type: :log, level: :info,
                       message: "guarded dispatch #{action} #{key.join(':')} pid=#{run[0]} start=#{run[1]} sample_epoch=#{permit[:epoch]} sample_sequence=#{permit[:sequence]} watchdog_episode=#{@episode.inspect}")
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
      label = result == :simulated ? "would #{permit[:action]}" : permit[:action]
      @workers.publish(type: :log, level: %i[success simulated].include?(result) ? :info : :warn,
                       message: "oomd #{label} #{key.join(':')} result=#{result} epoch=#{permit[:epoch]} sequence=#{permit[:sequence]}")
      return unless result == :success

      @workers.publish(type: 'osctl_oomd', opts: { pool: key[0], id: key[1], action: permit[:action], time: permit[:time] })
    end

    def break_links
      @records.each_value(&:break_link)
    end

    def publish_export
      values = @records.values.map(&:clone)
      status = {
        notification_drops: @workers.notification_drops,
        notification_failures: @workers.notification_failures,
        unknown_actions: @inflight.values.count { |permit| permit[:unknown] }
      }
      @export_mutex.synchronize do
        @export = values
        @status = status
      end
    end
  end
end
