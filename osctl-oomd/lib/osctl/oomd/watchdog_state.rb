require 'json'

module OsCtl::Oomd
  # A fresh distress frame is a host gate, never a container observation.
  class WatchdogState
    def initialize(path:, max_age_seconds:, latency_threshold_ms: 1000, sustain_seconds: 30, pending_seconds: 30, boot_id: File.read('/proc/sys/kernel/random/boot_id').strip)
      @cutoff_ns = latency_threshold_ms * 1_000_000
      @sustain_ns = sustain_seconds * 1_000_000_000
      @pending_ns = pending_seconds * 1_000_000_000
      @last_read_ns = nil
      @continuity = 0
      @activation = 0
      @active_proof = nil
      @diagnostic = nil
      @path = path
      @max_age_ns = (max_age_seconds * 1_000_000_000).to_i
      @boot_id = boot_id
      @epoch = nil
      @sequence = nil
      @observed = nil
      @frame = nil
      @bound = false
    end

    attr_reader :diagnostic, :details, :observation

    def episode(now_ns:)
      if @last_read_ns && now_ns - @last_read_ns > @max_age_ns
        invalidate
      end
      @last_read_ns = now_ns
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
      frame = read_frame
      @observation = diagnostic_observation(frame)
      now_ns += Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - started
      unless valid?(frame, now_ns) && valid_summary?(frame)
        @diagnostic = 'unavailable or incompatible watchdog latency coverage'
        return invalidate
      end
      @diagnostic = nil

      epoch = frame.fetch('epoch')
      sequence = frame.fetch('sequence')
      observed = frame.fetch('observed_monotonic_ns')
      if epoch != @epoch
        @epoch = epoch
        @sequence = sequence
        @observed = observed
        @frame = frame
        @bound = false
        @active_proof = nil
        @diagnostic = 'watchdog epoch binding needs advancing frames'
        return nil
      end

      return invalidate if sequence < @sequence || observed < @observed
      return invalidate if sequence == @sequence && frame != @frame

      @bound = true if sequence > @sequence && observed > @observed
      @sequence = sequence
      @observed = observed
      @frame = frame
      run = frame.fetch('latency_run')
      unless @bound && run['valid']
        @active_proof = nil
        @diagnostic = 'watchdog coverage not yet established'
        return nil
      end

      coverage = run.fetch('coverage_started_ns')
      @details = { frame_age_seconds: (now_ns - observed) / 1e9, cutoff_ns: run['cutoff_ns'],
                   coverage_started_ns: coverage, probe: frame['probe_sequence'],
                   span_seconds: run['slow_count'] > 0 ? (run['last_completed_ns'] - run['first_started_ns']) / 1e9 : nil,
                   pending_age_seconds: frame['started_monotonic_ns'] && ((now_ns - [frame['started_monotonic_ns'], coverage].max) / 1e9) }
      slow = run['slow_count'] > 0 && run['last_completed_ns'] - run['first_started_ns'] >= @sustain_ns
      pending_start = frame['started_monotonic_ns']
      pending = %w[pending distressed].include?(frame['state']) && pending_start &&
                frame['completed_monotonic_ns'].nil? && frame['error_code'] == 0 &&
                now_ns - [pending_start, coverage].max >= @pending_ns
      unless slow || pending
        @active_proof = nil
        return nil
      end

      proof = { epoch:, coverage:, generation: @continuity,
                slow: slow ? run['first_probe'] : nil,
                last_slow: slow ? run['last_probe'] : nil,
                pending: pending ? frame['probe_sequence'] : nil }
      unless continuous?(@active_proof, proof)
        @activation += 1
      end
      @active_proof = proof
      [epoch, coverage, @continuity, @activation]
    rescue SystemCallError, IOError, JSON::ParserError, KeyError, TypeError, ArgumentError
      @observation = { ordered_log_support: 'unknown', reason: 'read_error' }
      invalidate
    end

    protected

    def diagnostic_observation(frame)
      return { ordered_log_support: 'unknown', reason: 'invalid_frame' } unless frame.is_a?(Hash)

      marker = frame['log_evidence']
      supported = marker.is_a?(Hash) && marker['version'] == 1 && %w[ready backpressured draining].include?(marker['state'])
      { ordered_log_support: supported ? 'supported' : 'unverified_or_unsupported',
        ordered_log_state: supported ? marker['state'] : nil,
        # This is capability/pressure metadata, never a local-write receipt.
        cross_stream_complete: false,
        epoch: frame['epoch'], sequence: frame['sequence'], probe_sequence: frame['probe_sequence'],
        observed_monotonic_ns: frame['observed_monotonic_ns'], state: frame['state'],
        started_monotonic_ns: frame['started_monotonic_ns'], completed_monotonic_ns: frame['completed_monotonic_ns'],
        error_code: frame['error_code'], latency_run: frame['latency_run'] }
    end

    def read_frame
      File.open(@path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |io|
        stat = io.stat
        raise ArgumentError, 'unsafe watchdog state' unless stat.file? && stat.uid == 0 && stat.mode.nobits?(0o022)

        data = io.read(4097)
        raise ArgumentError, 'oversized watchdog state' if data.bytesize > 4096

        JSON.parse(data)
      end
    end

    def valid?(frame, now)
      return false unless frame.is_a?(Hash) && frame['schema'] == 1 && frame['boot_id'] == @boot_id
      return false unless frame['epoch'].is_a?(String) && frame['epoch'].bytesize.between?(1, 95) && frame['epoch'].ascii_only?
      return false unless positive?(frame['sequence']) && positive?(frame['probe_sequence'])
      return false unless frame['expected_errno'] == 22 && frame['error_code'].is_a?(Integer) && frame['error_code'].between?(0, 7)
      return false unless %w[starting pending distressed healthy error].include?(frame['state'])

      observed = frame['observed_monotonic_ns']
      return false unless positive?(observed) && observed <= now && now - observed <= @max_age_ns

      %w[dispatch_monotonic_ns started_monotonic_ns completed_monotonic_ns last_duration_ns].each do |key|
        return false unless frame.has_key?(key) && (frame[key].nil? || (frame[key].is_a?(Integer) && frame[key] >= 0))
        return false if key != 'last_duration_ns' && frame[key] && frame[key] > observed
      end
      dispatch = frame['dispatch_monotonic_ns']
      started = frame['started_monotonic_ns']
      completed = frame['completed_monotonic_ns']
      return false if started && (!dispatch || started < dispatch)
      return false if completed && (!started || completed < started)
      return false if frame['state'] == 'distressed' && (!started || completed || frame['error_code'] != 0)
      return false if frame['state'] == 'healthy' && (!completed || frame['error_code'] != 0)

      true
    end

    def continuous?(previous, current)
      return false unless previous && previous.values_at(:epoch, :coverage, :generation) == current.values_at(:epoch, :coverage, :generation)
      return true if previous[:slow] && previous[:slow] == current[:slow]
      return true if previous[:pending] && previous[:pending] == current[:pending]

      # A held pending probe may become a completed slow-run span. Its identity
      # must be inside that very consecutive run; an unseen fast reset fails.
      previous[:pending] && current[:slow] &&
        previous[:pending].between?(current[:slow], current[:last_slow])
    end

    def valid_summary?(frame)
      run = frame['latency_run']
      return false unless run.is_a?(Hash) && run['version'] == 1 && [true, false].include?(run['valid'])
      return false unless run['cutoff_ns'] == @cutoff_ns && run['interval_ns'].is_a?(Integer) && run['interval_ns'].between?(100_000_000, 1_000_000_000)
      return false unless positive?(run['tick_ns']) && run['tick_ns'].between?(50_000_000, 250_000_000)
      return false unless run['slow_count'].is_a?(Integer) && run['slow_count'] >= 0

      coverage = run['coverage_started_ns']
      return false unless coverage.nil? || (positive?(coverage) && coverage <= frame['observed_monotonic_ns'])
      return false if run['valid'] && (coverage.nil? || frame['error_code'] != 0 || frame['state'] == 'error')

      fields = %w[first_probe last_probe first_started_ns last_completed_ns]
      return fields.all? { |key| run.has_key?(key) && run[key].nil? } if run['slow_count'] == 0
      return false unless run['valid'] && fields.all? { |key| positive?(run[key]) }
      return false unless run['first_probe'] <= run['last_probe'] && run['last_probe'] <= frame['probe_sequence']
      return false unless run['slow_count'] == run['last_probe'] - run['first_probe'] + 1

      coverage <= run['first_started_ns'] && run['last_completed_ns'] - run['first_started_ns'] > @cutoff_ns &&
        run['last_completed_ns'] <= frame['observed_monotonic_ns']
    end

    def positive?(value)
      value.is_a?(Integer) && value > 0
    end

    def invalidate
      @details = nil
      @diagnostic ||= 'watchdog evidence unavailable'
      @continuity += 1
      @active_proof = nil
      @epoch = nil
      @sequence = nil
      @observed = nil
      @frame = nil
      @bound = false
      nil
    end
  end
end
