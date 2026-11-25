require 'securerandom'
require 'osctl/oomd/exposure_state'
require 'osctl/oomd/exposure_events'

module OsCtl::Oomd
  # Emits disjoint correlated observations; central policy owns rolling credit.
  class RtnlExposure
    DEFAULTS = { 'enable' => false, 'cache_file' => '/run/rtnl-watchdog-exposure.json' }.freeze
    WIRE_MAX = (2**63) - 1

    def self.settings(value)
      config = DEFAULTS.merge(value || {})
      raise ArgumentError, 'rtnl_exposure.enable must be boolean' unless [true, false].include?(config['enable'])
      unless config['cache_file'].is_a?(String) && config['cache_file'].start_with?('/') && config['cache_file'].bytesize < 4096
        raise ArgumentError, 'rtnl_exposure.cache_file must be absolute'
      end

      config
    end

    def initialize(interval:, cpu_percent:, memory_percent:, load_top:, settings:, reader: nil, publisher: nil, clock: nil,
                   boot_id: File.read('/proc/sys/kernel/random/boot_id').strip)
      @settings = self.class.settings(settings)
      @interval_us = interval * 1_000_000
      @policy = { cpu_percent_milli: (cpu_percent * 1000).floor, memory_percent_milli: (memory_percent * 1000).floor, load_top: }
      @reader = reader || ExposureState.new(path: @settings['cache_file'], boot_id:)
      @publisher = publisher || ExposureEvents.new
      @clock = clock || -> { [Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond), (Time.now.to_r * 1_000_000).to_i] }
      @boot = boot_id
      @emitted = {}
      @accounted = {}
      @gaps = @batches = @paused = 0
      reset_epoch
    end

    def enabled? = @settings['enable']

    def start
      @publisher.start if enabled?
    end

    def stop
      @publisher.stop if enabled?
    end

    def status
      { rtnl_exposure_enabled: enabled? ? 1 : 0, rtnl_exposure_available: @cache ? 1 : 0,
        rtnl_exposure_paused: @paused, rtnl_exposure_gaps: @gaps, rtnl_exposure_batches: @batches }.merge(@publisher.status)
    end

    def tick(now_ns:, watchdog:)
      return unless enabled?

      @cache = @reader.read(now_ns:, watchdog:)
      break_link(@cache ? 'cache_gap' : 'coverage_lost') if @reader.gap || !@cache
    end

    def break_link(reason = 'sample_gap')
      return unless enabled?

      @gaps += 1 unless @gap_reason
      @gap_reason ||= reason
      @previous = nil
      @accounted.clear
    end

    def observe(data, rows:, qualifications:, linked:, ranks: {})
      return unless enabled?

      completed = data.fetch('sample_completed_monotonic_ns') / 1000
      mono, wall = @clock.call
      offset = wall - (mono / 1000)
      if @offset && (offset - @offset).abs > 1_000_000
        reset_epoch('clock_change')
      end
      @offset = offset
      break_link unless linked && @previous && @previous[:epoch] == data['epoch'] && @previous[:sequence] + 1 == data['sequence']
      keys = rows.keys.select { |key| qualifications[key] == true || @emitted.has_key?(key) }.take(1025)
      targets = keys.to_h do |key|
        [key, proof(rows.fetch(key), qualifications[key], data, completed, ranks[key])]
      end
      selected = targets.select { |key, target| target[:qualification] == 'qualified' || (@emitted.has_key?(key) && state(target) != state(@emitted[key])) }
      (@emitted.keys - targets.keys).each do |key|
        selected[key] = vanished(@emitted.fetch(key))
      end
      segments = selected.to_h { |key, target| [key, contributions(key, target, completed, offset)] }
      positive = segments.values.any? { |values| !values.empty? }
      due = @last_emitted.nil? || completed - @last_emitted >= 15_000_000
      changed = selected.any? { |key, target| state(target) != state(@emitted[key]) }
      if (positive || due || changed || @gap_reason) && !emit(data, completed, offset, selected, segments, positive:)
        return
      end

      @previous = { epoch: data['epoch'], sequence: data['sequence'], completed:, targets: targets.size <= 1024 ? targets : {} }
      @accounted.select! { |(key, run, observer, probe), _| targets[key]&.[](:run) == run && @cache && observer == @cache['epoch'] && probe >= (@cache['records'].first&.[](1) || @cache.dig('pending', 'probe') || 0) }
    end

    protected

    def reset_epoch(reason = 'startup')
      @epoch = SecureRandom.hex(16)
      @sequence = 0
      @previous = @last_emitted = nil
      @gap_reason = reason
      @emitted.clear
      @accounted.clear
    end

    def state(target)
      target&.slice(:run, :qualification, :cpu_limit_state, :memory_limit_state)
    end

    def percent(value, limit)
      return unless value && limit && limit > 0

      result = value.to_f / limit * 100_000
      result.floor if result.finite? && result.between?(0, WIRE_MAX)
    end

    def proof(row, hit, data, completed, rank)
      run = if row['run_verified']
              { group_path: row['group_path'], init_pid: row['init_pid'], init_start_time_ticks: row['init_start_time_ticks'] }
            end
      previous = @previous&.dig(:targets, row.values_at('pool', 'id'))
      same = previous && previous[:run] == run && run
      linked = [true, false].include?(hit)
      linked &&= same && @previous[:completed] < completed && row['cpu_baseline_sequence'] == data['sequence'] - 1 &&
                 row['cpu_window_started_monotonic_ns'] == data['previous_sample_started_monotonic_ns']
      qualification = if hit == true
                        'qualified'
                      else
                        hit == false ? 'ineligible' : 'unknown'
                      end
      { pool: row['pool'], id: row['id'], run:, qualification:,
        previous_qualification: same ? previous[:qualification] : 'unknown', linked: linked == true,
        window_from_mono_us: linked ? [@previous[:completed], completed - @interval_us, row['cpu_window_started_monotonic_ns'] / 1000].max : nil,
        window_to_mono_us: linked ? completed : nil,
        cpu_percent_milli: percent(row['cpu_usage'], row['cpu_limit']), memory_percent_milli: percent(row['memory'], row['memory_limit']),
        cpu_limit_state: row['cpu_limit_state'], memory_limit_state: row['memory_limit_state'],
        rank:,
        reason: case qualification
                when 'ineligible'
                  'ineligible'
                when 'unknown'
                  Eligibility::Partial.decidable?(row) ? 'rank_unknown' : 'resource_unknown'
                else
                  linked ? nil : 'initial_baseline'
                end }
    end

    def vanished(target)
      target.merge(run: nil, qualification: 'unknown', previous_qualification: target[:qualification], linked: false,
                   window_from_mono_us: nil, window_to_mono_us: nil, cpu_percent_milli: nil, memory_percent_milli: nil,
                   cpu_limit_state: 'unknown', memory_limit_state: 'unknown', rank: nil, reason: 'vanished')
    end

    def contributions(key, target, completed, offset)
      return [] unless @cache && !@gap_reason && target[:linked] && target[:qualification] == 'qualified' && target[:previous_qualification] == 'qualified'

      probes = @cache['records'].map { |_, probe, started, ended, error, coverage, valid| [probe, started, ended, coverage, valid && error == 0] }
      if (pending = @cache['pending'])
        probes << [pending['probe'], pending['started_ns_or_null'], nil, pending['coverage_started_ns_or_null'], pending['coverage_valid']]
      end
      probes.filter_map do |probe, started, ended, coverage, valid|
        next unless valid && started && coverage

        start_us = started / 1000
        end_us = ended && (ended / 1000)
        observed = [@cache['observed_monotonic_ns'] / 1000, completed].min
        cursor = [key, target[:run], @cache['epoch'], probe]
        from = [target[:window_from_mono_us], start_us + 1_000_000, coverage / 1000, @accounted[cursor] || 0].max
        to = [target[:window_to_mono_us], end_us || observed, observed].min
        next unless from < to

        @accounted[cursor] = to
        pending_at_observation = !end_us || end_us > completed
        { probe:, probe_started_mono_us: start_us, probe_completed_mono_us: pending_at_observation ? nil : end_us,
          coverage_started_mono_us: coverage / 1000, from_mono_us: from, to_mono_us: to,
          from_at_us: offset + from, to_at_us: offset + to, credit_us: to - from,
          peak_latency_us: (pending_at_observation ? observed : end_us) - start_us, peak_is_lower_bound: pending_at_observation }
      end
    end

    def identity_fits?(target)
      %i[pool id].all? { |key| target[key].is_a?(String) && target[key].valid_encoding? && target[key].bytesize.between?(1, 255) } &&
        (!target[:run] || (target[:run][:group_path].is_a?(String) && target[:run][:group_path].valid_encoding? &&
                          target[:run][:group_path].bytesize.between?(1, 1024) &&
                          %i[init_pid init_start_time_ticks].all? { |key| target[:run][key].is_a?(Integer) && target[:run][key].between?(1, WIRE_MAX) }))
    end

    def emit(data, completed, offset, selected, segments, positive:)
      @sequence += 1
      unless data['epoch'].ascii_only? && data['epoch'].bytesize.between?(1, 95) &&
             [@sequence, data['sequence'], @interval_us].all? { |value| value.is_a?(Integer) && value.between?(1, WIRE_MAX) } &&
             [completed, completed + offset, *@policy.values].all? { |value| value.is_a?(Integer) && value.between?(0, WIRE_MAX) }
        break_link('oversize')
        return false
      end
      complete = selected.size <= 1024 && selected.values.all? { |target| identity_fits?(target) }
      gap = complete ? @gap_reason : 'oversize'
      header = { schema: 1, kind: positive ? 'sample' : 'heartbeat', producer_epoch: @epoch, boot_id: @boot,
                 observer_epoch: @cache ? @cache['epoch'] : 'unavailable', sequence: @sequence, batch_id: "#{@epoch}:#{@sequence}",
                 observed_at_us: completed + offset, observed_mono_us: completed, sample_epoch: data['epoch'], sample_sequence: data['sequence'],
                 interval_us: @interval_us, cutoff_us: 1_000_000, coverage_started_mono_us: @cache && (@cache['coverage_started_ns'] / 1000),
                 coverage_valid: !@cache.nil?, gap_since_previous: !gap.nil?, gap_reason: gap,
                 targets_complete: complete, roster_complete: data['inventory_complete'], policy: @policy }
      parts = complete ? partition(selected, segments, header) : [{ targets: [], segments: [] }]
      unless parts && parts.size <= 64
        parts = [{ targets: [], segments: [] }]
        header.merge!(targets_complete: false, gap_since_previous: true, gap_reason: 'oversize')
      end
      events = parts.each_with_index.map { |part, i| { type: 'osctl_oomd_rtnl_exposure', opts: header.merge(parts: parts.size, part: i + 1).merge(part) } }
      if events.any? { |event| JSON.generate(event[:opts]).bytesize > 16_384 } || !@publisher.publish(events)
        @paused = 1
        break_link('pressure')
        return
      end
      @paused = 0
      @batches += 1
      @last_emitted = completed
      @emitted = selected.select { |_, target| target[:qualification] == 'qualified' } if header[:targets_complete]
      break_link('oversize') unless header[:targets_complete]
      return unless header[:targets_complete]

      @gap_reason = nil
      true
    end

    def partition(selected, segments, header)
      parts = []
      selected.each do |key, target|
        units = segments.fetch(key)
        units = [nil] if units.empty?
        units.each do |segment|
          loop do
            parts << { targets: [], segments: [] } if parts.empty?
            last = parts.last
            index = last[:targets].index(target)
            next_targets = index ? last[:targets] : last[:targets] + [target]
            index ||= last[:targets].size
            next_segments = last[:segments] + (segment ? [segment.merge(target: index)] : [])
            candidate = { targets: next_targets, segments: next_segments }
            if next_targets.size <= 16 && next_segments.size <= 16 && JSON.generate(header.merge(part: 64, parts: 64).merge(candidate)).bytesize <= 16_384
              parts[-1] = candidate
              break
            end
            return nil if last[:targets].empty? || parts.size >= 64

            parts << { targets: [], segments: [] }
          end
        end
      end
      parts.empty? ? [{ targets: [], segments: [] }] : parts
    end
  end
end
