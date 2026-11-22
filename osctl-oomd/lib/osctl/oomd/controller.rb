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
      'restart_hits' => 2,
      'observation_max_age_seconds' => 5,
      'action_workers' => 2
    }.freeze

    attr_reader :stop_hits, :episode, :inflight

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
        raise ArgumentError, "invalid rtnl_watchdog.#{key}" unless value.is_a?(Numeric) && value.finite? && value > 0
      end
      unless config['restart_hits'].is_a?(Integer) && config['restart_hits'] >= 2
        raise ArgumentError, 'rtnl_watchdog.restart_hits must be at least 2'
      end
      unless config['action_workers'].is_a?(Integer) && config['action_workers'].between?(1, 2)
        raise ArgumentError, 'rtnl_watchdog.action_workers must be 1 or 2'
      end

      config
    end

    def initialize(interval:, cpu_percent:, memory_percent:, load_multiplier:, load_top:, restart_hits:, stop_hits:,
                   rtnl_watchdog:, dry_run: false, host_load: nil, watchdog: nil, workers: nil, executor: nil, verbose: false)
      @settings = self.class.settings(rtnl_watchdog)
      @interval_ns = (interval * 1_000_000_000).to_i
      @sample_max_age_ns = (@settings.fetch('observation_max_age_seconds') * 1_000_000_000).to_i
      @cpu_percent = cpu_percent
      @memory_percent = memory_percent
      @load_multiplier = load_multiplier
      @load_top = load_top
      @ordinary_restart_hits = restart_hits
      @stop_hits = stop_hits
      @host_load = host_load || HostLoad.new(interval)
      @verbose = verbose
      @cold_loads = []
      @raw_epochs = {}
      @raw_broken = false
      if @settings.fetch('enable')
        @watchdog = watchdog || WatchdogState.new(path: @settings.fetch('state_file'), max_age_seconds: @settings.fetch('max_age_seconds'))
      end
      @workers = workers || ActionWorkers.new(size: @settings.fetch('action_workers'), dry_run:, executor:)
      @records = {}
      @runs = {}
      @inflight = {}
      @export_mutex = Mutex.new
      @export = []
      @status = { notification_drops: 0, notification_failures: 0, unknown_actions: 0 }
      @episode = nil
      @episode_started = nil
      @stopping = false
    end

    def start
      @workers.start
    end

    def stop
      @stopping = true
      @workers.stop
    end

    def restart_hits
      @episode ? @settings.fetch('restart_hits') : @ordinary_restart_hits
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
      if next_episode != @episode
        clear_restart
        @episode = next_episode
        @episode_started = next_episode ? now_ns : nil
      end
      if @raw && now_ns > @raw.data.fetch('sample_completed_monotonic_ns') + @interval_ns + @sample_max_age_ns
        @raw_broken = true
        clear_restart if @episode
      end
      @workers.completions { |permit, result| complete_action(permit, result) }
      publish_export
    end

    def child_started
      @bootstrap = true
      @child_epoch = nil
      @raw_broken = true
      @cold_loads.clear
      clear_restart if @episode
    end

    def invalidate
      @bootstrap = false
      @raw_broken = true
      clear_restart if @episode
      publish_export
      false
    end

    def observe(data, now_ns: monotonic_ns)
      processing_started = monotonic_ns
      tick(now_ns:)
      bootstrap = @bootstrap
      @bootstrap = false
      observe_packet(data, now_ns, processing_started, bootstrap:)
    end

    protected

    def observe_complete(data, rows, now_ns, processing_started)
      load = data.fetch('loadavg').fetch(0)
      @cold_loads.clear
      @host_load << load
      @load_gate = load_gate(load, @host_load.median)
      if @verbose
        @workers.publish(type: :log, level: :debug, message: "Load=#{load}, median=#{@host_load.median}, threshold=#{@host_load.median * @load_multiplier}")
        @workers.publish(type: :log, level: :debug, message: @load_gate ? 'OOMd active' : 'OOMd inactive')
      end
      ranked = Eligibility.rank(data.fetch('containers'))
      rows.each do |key, ct|
        run = [ct.fetch('init_pid'), ct.fetch('init_start_time_ticks')]
        record = (@records[key] ||= ContainerScore.new(*key))
        update_run(record, key, ct)
        hit = hit?(ct, ranked)
        # Every accelerated hit is raw and began after this episode's entry.
        score_restart = !@inflight.has_key?(key) && (@episode ? data.fetch('sample_started_monotonic_ns') > @episode_started : @load_gate)
        score_stop = @load_gate
        next unless score_restart || score_stop

        changed = hit || (score_restart && record.restart_hits > 0) || (score_stop && record.stop_hits > 0)
        record.public_send(hit ? :hit : :miss, restart: score_restart, stop: score_stop)
        if changed
          @workers.publish(type: :log, level: :info,
                           message: "#{key.join(':')} #{hit ? 'hit' : 'miss'}, #{record.restart_hits}/#{restart_hits} restart hits, #{record.stop_hits}/#{stop_hits} stop hits")
        end
        next unless hit && (@load_gate || @episode)

        action = if @load_gate && record.stop_hits >= stop_hits
                   :stop
                 elsif score_restart && record.restart_hits >= restart_hits
                   :restart
                 end
        dispatch(ct, key, run, action, now_ns, processing_started) if action
      end
      # Disappearance invalidates restart evidence; stop history retains the
      # ordinary success/reset semantics across restarts and inventory sweeps.
      (@records.keys - rows.keys).each do |key|
        record = @records.fetch(key)
        record.reset_restart_hits
        next if @inflight.has_key?(key) || record.stop_hits > 0

        @records.delete(key)
        @runs.delete(key)
      end
      publish_export
      true
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
      clear_restart if @episode && !linked
      full = data['complete'] && ((new_epoch && bootstrap) || (linked && previous.strict_seed && same_runs?(rows, previous.rows)))
      seed = coherent_seed || data['complete']
      @raw = RawFrame.new(data:, rows:, strict_seed: seed)
      @raw_broken = false
      @cold_loads.clear if seed
      return observe_complete(data, rows, now, processing_started) if full

      if !data['complete'] && data['inventory_complete']
        cold_gate = update_cold_history(data) unless seed
        return score_partial(data, rows, previous.rows, now, processing_started, cold_gate) if linked
      end
      clear_restart if @episode
      publish_export
      false
    end

    def packet_rows(data)
      rows = Eligibility::Partial.index(data)
      return unless rows && rows.values.all? { |row| row['cpu_usage'].nil? || matching_cpu_window?(row, data) }

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
      STRICT_SEED_REASONS.include?(data['invalid_reason']) && rows.values.all? { |row| cpu_seed?(row) }
    end

    def cpu_seed?(row)
      return false unless row

      reason = row['errors']['cpu_usage']
      row['cpu_usage'] || STRICT_SEED_REASONS.include?(reason)
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

    def score_partial(data, rows, previous, now, processing_started, cold_gate)
      gate = partial_load_gate(data)
      restart_gate = gate.nil? ? cold_gate : gate
      roster = data.fetch('containers')
      ranked = Eligibility.rank(roster) if roster.all? { |row| row['loadavg'] }
      rows.each do |key, row|
        # Match the same key, cgroup path and process at both raw endpoints.
        identity = Eligibility::Partial.run(row)
        run = identity&.drop(1)
        record = (@records[key] ||= ContainerScore.new(*key))
        update_run(record, key, row)
        unless identity && identity == Eligibility::Partial.run(previous[key]) && cpu_seed?(previous[key]) &&
               Eligibility::Partial.decidable?(row) && matching_cpu_window?(row, data)
          record.reset_restart_hits if @episode
          next
        end
        rank = Eligibility.rank_proof(row, roster, ranked, @load_top)
        if rank.nil?
          record.reset_restart_hits if @episode
          next
        end
        next if @inflight.has_key?(key) || !restart_gate?(data, restart_gate)

        hit = rank && Eligibility.resource_hit?(row, memory_percent: @memory_percent, cpu_percent: @cpu_percent)
        next if hit && stop_has_priority?(record, gate)

        record.public_send(hit ? :hit : :miss, restart: true, stop: false)
        if hit && record.restart_hits >= restart_hits
          dispatch(row, key, run, :restart, now, processing_started, partial: data, cold_gate:)
        end
      end
      (@records.keys - rows.keys).each { |key| @records.fetch(key).reset_restart_hits }
      publish_export
      true
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
      load = data['loadavg']&.first
      load_gate(load, @host_load.median_with(load)) if load
    end

    def load_gate(load, median)
      return if median.nil?

      threshold = median * @load_multiplier
      load >= threshold if Eligibility::Partial.reading?(threshold)
    end

    def restart_gate?(data, gate)
      @episode ? data['sample_started_monotonic_ns'] > @episode_started : gate
    end

    def stop_has_priority?(record, gate)
      record.stop_hits >= stop_hits || (gate != false && record.stop_hits + 1 >= stop_hits)
    end

    def monotonic_ns
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    end

    def positive?(value)
      value.is_a?(Integer) && value > 0
    end

    def hit?(ct, ranked)
      Eligibility.hit?(ct, ranked, memory_percent: @memory_percent, cpu_percent: @cpu_percent, load_top: @load_top)
    end

    def run_identity(row)
      Eligibility::Partial.run(row)
    end

    def update_run(record, key, row)
      identity = run_identity(row)
      record.reset_restart_hits if @runs[key] != identity
      @runs[key] = identity
    end

    def dispatch(ct, key, run, action, now, processing_started, partial: nil, cold_gate: nil)
      # Re-read the independent host gate and effective threshold at grant,
      # even if scoring or another candidate took time since the first tick.
      tick(now_ns: now + (monotonic_ns - processing_started))
      # No deferred permit queue: recheck this exact current frame/run at grant.
      frame = @raw.data
      return if @stopping || @inflight.has_key?(key) || @raw_broken
      return unless @raw.rows[key].equal?(ct) && @runs[key] == run_identity(ct) && run == ct.values_at('init_pid', 'init_start_time_ticks')

      record = @records.fetch(key)
      if partial
        return unless action == :restart && frame.equal?(partial)

        gate = partial_load_gate(partial)
        return unless restart_gate?(partial, gate.nil? ? cold_gate : gate) && !stop_has_priority?(record, gate)
      else
        return unless @load_gate || @episode
        return if action == :stop && (!@load_gate || record.stop_hits < stop_hits)
      end
      return if action == :restart && record.restart_hits < restart_hits

      deadline = frame.fetch('sample_completed_monotonic_ns') + @sample_max_age_ns
      permit = { pool: key[0], id: key[1], run:, action:, epoch: frame['epoch'], sequence: frame['sequence'],
                 watchdog_episode: @episode, time: Time.now.to_i }
      # This is an enqueue deadline, not a deadline on the daemon's action.
      return if now + (monotonic_ns - processing_started) > deadline
      return unless @workers.dispatch(permit)

      @inflight[key] = permit
      @records.fetch(key).reset_restart_hits
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
        record&.reset_restart_hits
        record&.reset_stop_hits if %i[success simulated].include?(result) && permit[:action] == :stop
      end
      label = result == :simulated ? "would #{permit[:action]}" : permit[:action]
      @workers.publish(type: :log, level: %i[success simulated].include?(result) ? :info : :warn,
                       message: "oomd #{label} #{key.join(':')} result=#{result} epoch=#{permit[:epoch]} sequence=#{permit[:sequence]}")
      return unless result == :success

      @workers.publish(type: 'osctl_oomd', opts: { pool: key[0], id: key[1], action: permit[:action], time: permit[:time] })
    end

    def clear_restart
      @records.each_value(&:reset_restart_hits)
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
