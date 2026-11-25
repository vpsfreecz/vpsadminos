require 'json'

module OsCtl::Oomd
  # A bounded observation cache, independent of the acute gate reader.
  class ExposureState
    LIMIT = 32_768
    UINT64 = (2**64) - 1

    attr_reader :gap

    def initialize(path:, boot_id: File.read('/proc/sys/kernel/random/boot_id').strip)
      @path = path
      @boot = boot_id
    end

    def read(now_ns:, watchdog:)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
      value = read_file
      now_ns += Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - started
      raise ArgumentError, 'invalid exposure cache' unless valid?(value, now_ns, watchdog)

      changed = @last && value['epoch'] != @last['epoch']
      @gap = @last.nil? || changed
      if @last && !changed
        old = @last
        raise ArgumentError, 'cache regressed' if value['observed_monotonic_ns'] < old['observed_monotonic_ns'] || value['last_sequence'] < old['last_sequence']
        raise ArgumentError, 'cache changed without advancing' if value['observed_monotonic_ns'] == old['observed_monotonic_ns'] && value != old

        @gap ||= value['first_sequence'] > old['last_sequence'] + 1
        @gap ||= value['records'].any? { |record| record[0] > old['last_sequence'] && record[4] != 0 }
        @gap ||= value['coverage_started_ns'] != old['coverage_started_ns']
        retained = old['records'].to_h { |record| [record[0], record] }
        raise ArgumentError, 'terminal changed' if value['records'].any? { |record| retained.has_key?(record[0]) && retained[record[0]] != record }
      end
      @last = value
      value
    rescue SystemCallError, IOError, JSON::ParserError, ArgumentError, TypeError
      @last = nil
      @gap = true
      nil
    end

    protected

    def read_file
      File.open(@path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |io|
        st = io.stat
        raise ArgumentError, 'unsafe exposure cache' unless st.file? && st.uid == 0 && (st.mode & 0o7777) == 0o600

        bytes = io.read(LIMIT + 1)
        raise ArgumentError, 'oversized exposure cache' if bytes.bytesize > LIMIT

        JSON.parse(bytes)
      end
    end

    def uint?(value) = value.is_a?(Integer) && value.between?(0, UINT64)
    def positive?(value) = uint?(value) && value > 0
    def optional_time?(value, now) = value.nil? || (positive?(value) && value <= now)

    def valid?(value, now, watchdog)
      return false unless value.is_a?(Hash) && value['schema'] == 1 && value['boot_id'] == @boot
      return false unless watchdog.is_a?(Hash) && value['epoch'] == watchdog[:epoch] && watchdog[:boot_id] == @boot && watchdog[:error_code] == 0
      return false unless value['epoch'].is_a?(String) && value['epoch'].ascii_only? && value['epoch'].bytesize.between?(1, 95)

      observed = value['observed_monotonic_ns']
      return false unless positive?(observed) && observed <= now && now - observed <= 1_000_000_000

      primary = watchdog[:observed_monotonic_ns]
      run = watchdog[:latency_run]
      return false unless positive?(primary) && primary <= now && now - primary <= 1_000_000_000 &&
                          run.is_a?(Hash) && run['version'] == 1 && run['cutoff_ns'] == 1_000_000_000 && run['valid'] == true &&
                          run['tick_ns'].is_a?(Integer) && run['tick_ns'].between?(50_000_000, 250_000_000)
      return false unless value['cutoff_ns'] == 1_000_000_000 && uint?(value['interval_ns']) && value['interval_ns'].between?(100_000_000, 1_000_000_000) && value['interval_ns'] == run['interval_ns']
      return false unless value['coverage_valid'] == true && value['paused'] == false && positive?(value['coverage_started_ns']) && value['coverage_started_ns'] <= observed

      return false unless (value.keys & %w[coverage_started_ns pending records first_sequence last_sequence]).size == 5

      records = value['records']
      return false unless records.is_a?(Array) && records.size <= 128 && records.all? { |record| terminal?(record, observed) }
      return false unless uint?(value['first_sequence']) && uint?(value['last_sequence'])

      if records.empty?
        return false unless value['first_sequence'] == 0 && value['last_sequence'] == 0
      else
        return false unless value['first_sequence'] == records.first[0] && value['last_sequence'] == records.last[0]
        return false unless records.each_cons(2).all? { |a, b| b[0] == a[0] + 1 && b[1] > a[1] && b[3] >= a[3] }
      end
      pending = value['pending']
      return true if pending.nil?
      return false unless pending.is_a?(Hash) && positive?(pending['probe']) && optional_time?(pending['started_ns_or_null'], observed) &&
                          pending.has_key?('started_ns_or_null') && pending.has_key?('coverage_started_ns_or_null') &&
                          optional_time?(pending['coverage_started_ns_or_null'], observed) && [true, false].include?(pending['coverage_valid'])
      return false if pending['coverage_valid'] && (!pending['started_ns_or_null'] || !pending['coverage_started_ns_or_null'])

      records.empty? || pending['probe'] > records.last[1]
    end

    def terminal?(record, observed)
      return false unless record.is_a?(Array) && record.size == 7

      sequence, probe, started, completed, error, coverage, valid = record
      positive?(sequence) && positive?(probe) && optional_time?(started, observed) && positive?(completed) && completed <= observed &&
        (!started || started <= completed) && error.is_a?(Integer) && error.between?(0, 7) &&
        optional_time?(coverage, observed) && [true, false].include?(valid) &&
        (!valid || (error == 0 && started && coverage && coverage <= completed))
    end
  end
end
