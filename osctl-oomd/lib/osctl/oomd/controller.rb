require 'libosctl'
require 'osctl/oomd/watchdog_state'
require 'osctl/oomd/action_workers'

module OsCtl::Oomd
  # The sole owner of scores and permits in opt-in watchdog mode.
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
                   rtnl_watchdog:, dry_run: false, host_load: nil, watchdog: nil, workers: nil, executor: nil)
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
      @watchdog = watchdog || WatchdogState.new(path: @settings.fetch('state_file'), max_age_seconds: @settings.fetch('max_age_seconds'))
      @workers = workers || ActionWorkers.new(size: @settings.fetch('action_workers'), dry_run:, executor:)
      @records = {}
      @runs = {}
      @inflight = {}
      @export_mutex = Mutex.new
      @export = []
      @status = { notification_drops: 0, notification_failures: 0, unknown_actions: 0 }
      @epoch = nil
      @sampler_epochs = {}
      @sequence = nil
      @last_valid_completed = nil
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
      next_episode = @watchdog.episode(now_ns:)
      if next_episode != @episode
        clear_restart
        @episode = next_episode
        @episode_started = next_episode ? now_ns : nil
      end
      if @last_valid_completed && now_ns > @last_valid_completed + @interval_ns + @sample_max_age_ns
        clear_restart if @episode
        @snapshot = nil
      end
      @workers.completions { |permit, result| complete_action(permit, result) }
      publish_export
    end

    # Only a newly accepted complete raw sweep may score or authorize commands.
    def observe(data, now_ns: monotonic_ns)
      processing_started = monotonic_ns
      tick(now_ns:)
      # A retired sampler epoch cannot become current again through delayed
      # packets. Reject it without accepting a transition or scoring it twice.
      if data.is_a?(Hash) && data['epoch'] != @epoch && @sampler_epochs.has_key?(data['epoch'])
        return false
      end

      unless valid_frame?(data, now_ns)
        clear_restart if @episode
        @snapshot = nil
        publish_export
        return false
      end
      epoch = data.fetch('epoch')
      sequence = data.fetch('sequence')
      if epoch == @epoch && sequence == @sequence
        clear_restart if @episode && data != @snapshot
        publish_export
        return false
      end
      if epoch == @epoch && @last_valid_completed && data.fetch('sample_started_monotonic_ns') <= @last_valid_completed
        clear_restart if @episode
        @snapshot = nil
        publish_export
        return false
      end

      if @episode && (epoch != @epoch || (@sequence && sequence != @sequence + 1))
        clear_restart
      end
      if epoch == @epoch && @sequence && sequence < @sequence
        @snapshot = nil
        publish_export
        return false
      end
      @epoch = epoch
      @sampler_epochs[epoch] = true
      @sequence = sequence
      @last_valid_completed = data.fetch('sample_completed_monotonic_ns')
      @snapshot = data
      @host_load << data.fetch('loadavg').fetch(0)
      @load_gate = data.fetch('loadavg').fetch(0) >= @host_load.median * @load_multiplier
      ranked = data.fetch('containers').sort { |a, b| b.fetch('loadavg').fetch(0) <=> a.fetch('loadavg').fetch(0) }
      live_keys = []
      data.fetch('containers').each do |ct|
        next if ct['pool'].nil? # Keep host in ranking, never target it.

        key = [ct.fetch('pool'), ct.fetch('id')]
        live_keys << key
        run = [ct.fetch('init_pid'), ct.fetch('init_start_time_ticks')]
        record = (@records[key] ||= Killer::Container.new(*key))
        record.reset_restart_hits if @runs[key] != run
        @runs[key] = run
        hit = hit?(ct, ranked)
        # Every accelerated hit is raw and began after this episode's entry.
        score_restart = !@inflight.has_key?(key) && (@episode ? data.fetch('sample_started_monotonic_ns') > @episode_started : @load_gate)
        score_stop = @load_gate
        next unless score_restart || score_stop

        record.public_send(hit ? :hit : :miss, restart: score_restart, stop: score_stop)
        @workers.publish(type: :log, level: :info,
                         message: "#{key.join(':')} #{hit ? 'hit' : 'miss'}, #{record.restart_hits}/#{restart_hits} restart hits, #{record.stop_hits}/#{stop_hits} stop hits")
        next unless hit && (@load_gate || @episode)

        action = if @load_gate && record.stop_hits >= stop_hits
                   :stop
                 elsif score_restart && record.restart_hits >= restart_hits
                   :restart
                 end
        dispatch(ct, key, run, action, now_ns + monotonic_ns - processing_started) if action
      end
      # Disappearance invalidates restart evidence; stop history retains the
      # ordinary success/reset semantics across restarts and inventory sweeps.
      (@records.keys - live_keys).each do |key|
        record = @records.fetch(key)
        record.reset_restart_hits
        next if @inflight.has_key?(key) || record.stop_hits > 0

        @records.delete(key)
        @runs.delete(key)
      end
      publish_export
      true
    end

    protected

    def monotonic_ns
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    end

    def positive?(value)
      value.is_a?(Integer) && value > 0
    end

    def finite_nonnegative?(value)
      value.is_a?(Numeric) && value.finite? && value >= 0
    end

    def valid_frame?(data, now)
      return false unless data.is_a?(Hash) && data['oomd_schema'] == 1 && data['complete'] == true
      return false unless data['epoch'].is_a?(String) && data['epoch'].bytesize.between?(1, 95) && positive?(data['sequence'])

      started = data['sample_started_monotonic_ns']
      completed = data['sample_completed_monotonic_ns']
      return false unless positive?(started) && positive?(completed) && started <= completed && completed <= now
      return false if completed - started > @sample_max_age_ns || now - completed > @sample_max_age_ns

      window_start = data['measurement_window_started_monotonic_ns']
      return false unless positive?(window_start) && window_start < started
      return false unless data['measurement_window_completed_monotonic_ns'] == completed
      return false unless data['loadavg'].is_a?(Array) && finite_nonnegative?(data['loadavg'][0])
      return false unless data['containers'].is_a?(Array)

      keys = []
      data['containers'].all? do |ct|
        next false unless ct.is_a?(Hash) && ct['loadavg'].is_a?(Array) && finite_nonnegative?(ct['loadavg'][0])

        key = [ct['pool'], ct['id']]
        next false if keys.include?(key)

        keys << key
        next ct['id'] == '[host]' if ct['pool'].nil?
        next false unless ct['pool'].is_a?(String) && ct['id'].is_a?(String) && ct['valid'] == true
        next false unless positive?(ct['init_pid']) && positive?(ct['init_start_time_ticks'])
        next false unless finite_nonnegative?(ct['memory']) && finite_nonnegative?(ct['cpu_usage'])
        next false unless ct['memory_limit'].nil? || (finite_nonnegative?(ct['memory_limit']) && ct['memory_limit'] > 0)
        next false unless ct['cpu_limit'].nil? || (finite_nonnegative?(ct['cpu_limit']) && ct['cpu_limit'] > 0)

        true
      end
    end

    def hit?(ct, ranked)
      Eligibility.hit?(ct, ranked, memory_percent: @memory_percent, cpu_percent: @cpu_percent, load_top: @load_top)
    end

    def dispatch(ct, key, run, action, now)
      # Re-read the independent host gate and effective threshold at grant,
      # even if scoring or another candidate took time since the first tick.
      grant_started = monotonic_ns
      tick(now_ns: now)
      now += monotonic_ns - grant_started
      # No deferred permit queue: recheck this exact current frame/run at grant.
      return if @stopping || @inflight.has_key?(key) || @snapshot.nil?
      return if now - @snapshot.fetch('sample_completed_monotonic_ns') > @sample_max_age_ns
      return unless @runs[key] == run && run == [ct['init_pid'], ct['init_start_time_ticks']]
      return unless @load_gate || @episode

      record = @records.fetch(key)
      return if action == :stop && (!@load_gate || record.stop_hits < stop_hits)
      return if action == :restart && record.restart_hits < restart_hits

      permit = { pool: key[0], id: key[1], run:, action:, epoch: @epoch, sequence: @sequence, watchdog_episode: @episode, time: Time.now.to_i }
      return unless @workers.dispatch(permit)

      @inflight[key] = permit
      @records.fetch(key).reset_restart_hits
      @workers.publish(type: :log, level: :info,
                       message: "guarded dispatch #{action} #{key.join(':')} pid=#{run[0]} start=#{run[1]} sample_epoch=#{@epoch} sample_sequence=#{@sequence} watchdog_episode=#{@episode.inspect}")
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
        record&.reset_stop_hits if result == :success && permit[:action] == :stop
      end
      @workers.publish(type: :log, level: result == :success ? :info : :warn,
                       message: "oomd #{permit[:action]} #{key.join(':')} result=#{result} epoch=#{permit[:epoch]} sequence=#{permit[:sequence]}")
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
