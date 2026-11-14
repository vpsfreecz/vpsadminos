require 'json'

module OsCtl::Oomd
  # A fresh distress frame is a host gate, never a container observation.
  class WatchdogState
    def initialize(path:, max_age_seconds:, boot_id: File.read('/proc/sys/kernel/random/boot_id').strip)
      @path = path
      @max_age_ns = (max_age_seconds * 1_000_000_000).to_i
      @boot_id = boot_id
      @epoch = nil
      @sequence = nil
      @observed = nil
      @frame = nil
      @bound = false
    end

    def episode(now_ns:)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
      frame = read_frame
      now_ns += Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - started
      return invalidate unless valid?(frame, now_ns)

      epoch = frame.fetch('epoch')
      sequence = frame.fetch('sequence')
      observed = frame.fetch('observed_monotonic_ns')
      if epoch != @epoch
        @epoch = epoch
        @sequence = sequence
        @observed = observed
        @frame = frame
        @bound = false
        return nil
      end

      return invalidate if sequence < @sequence || observed < @observed
      return invalidate if sequence == @sequence && frame != @frame

      @bound = true if sequence > @sequence && observed > @observed
      @sequence = sequence
      @observed = observed
      @frame = frame
      return nil unless @bound && frame['state'] == 'distressed'

      [epoch, frame.fetch('probe_sequence')]
    rescue SystemCallError, IOError, JSON::ParserError, KeyError, TypeError, ArgumentError
      invalidate
    end

    protected

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

    def positive?(value)
      value.is_a?(Integer) && value > 0
    end

    def invalidate
      @epoch = nil
      @sequence = nil
      @observed = nil
      @frame = nil
      @bound = false
      nil
    end
  end
end
