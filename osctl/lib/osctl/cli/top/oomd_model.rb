require 'securerandom'
require 'osctl/cli/top/model'
require 'osctl/cli/top/measurement'
require 'osctl/cli/top/host'

module OsCtl::Cli
  # The eligibility sampler never constructs the ordinary optional collectors.
  class Top::OomdModel < Top::Model
    MAX_SWEEP_NS = 5_000_000_000
    COUNTERS = %i[cpu_hz cpu_user_hz cpu_system_hz].freeze

    class InvalidSample < StandardError
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super
      end
    end

    class Measurement < Top::Measurement
      attr_reader :failed_limit_read

      def measure
        @time = Time.now
        reader = OsCtl::Lib::CGroup::PathReader.new(subsystems, group_path)
        raw = reader.read_stats(%i[cpu_hz cpu_limit memory memory_limit], true)
        # PathReader omits an unlimited limit; an explicit nil means ENOENT.
        @failed_limit_read = %i[cpu_limit memory_limit].any? { |k| raw.has_key?(k) && raw[k].nil? }
        @data = raw.transform_values { |v| v.is_a?(OsCtl::Lib::Cli::Presentable) ? v.raw : v }
        @data[:cpu_limit] = nil unless @data.has_key?(:cpu_limit)
        @data[:memory_limit] = nil unless @data.has_key?(:memory_limit)
      rescue SystemCallError => e
        raise Top::Measurement::Error, e.message
      end
    end

    attr_reader :data

    # Model#initialize constructs the optional collectors this path must avoid.
    def initialize # rubocop:disable Lint/MissingSuper
      @epoch = SecureRandom.uuid
      @sequence = 0
      @baseline = nil
      @data = {}
    end

    def setup
      @nproc = IO.popen(['nproc'], &:read).strip.to_i
      measure
    end

    def stop; end

    def measure
      @sequence += 1
      started = monotonic_ns

      begin
        raw = acquire(started)
        raw[:completed] = monotonic_ns
        if raw[:completed] < started || raw[:completed] - started > MAX_SWEEP_NS
          raise InvalidSample, 'stale_sweep'
        end
      rescue StandardError => e
        @baseline = nil
        reason = e.is_a?(InvalidSample) ? e.reason : 'required_read_failed'
        @data = invalid_frame(started, monotonic_ns, reason)
        return
      end

      reason = delta_error(raw, @baseline)
      @data = project(raw, @baseline, reason)
      # Coherent raw data seeds the next interval even during delta warm-up.
      @baseline = raw
    end

    protected

    def monotonic_ns
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    end

    def acquire(started)
      raise InvalidSample, 'invalid_cpu_count' unless nproc && nproc > 0

      client = OsCtl::Client.new
      begin
        client.open
        subsystems = client.cmd_data!(:group_cgsubsystems) if OsCtl::Lib::CGroup.v1?
        inventory = read_inventory(client)
        cpu = read_cpu
        memory = read_memory
        loadavg = valid_load(OsCtl::Lib::LoadAvg.new.to_a)
        runs = {}
        measurements = {}

        inventory.each do |ct|
          key = [ct[:pool], ct[:id]]
          runs[key] = init_start_time(ct[:init_pid])
          measurement = Measurement.new(nil, subsystems, ct[:group_path], nil, [])
          measurement.measure
          validate_measurement(measurement)
          measurements[key] = measurement
        end

        loads = inventory.empty? ? {} : OsCtl::Lib::LoadAvgReader.read_for(inventory)
        inventory.each do |ct|
          entry = loads["#{ct[:pool]}:#{ct[:id]}"]
          raise InvalidSample, 'missing_container_load' unless entry

          valid_load(entry.averages)
        end

        unless inventory == read_inventory(client)
          raise InvalidSample, 'inventory_changed'
        end

        inventory.each do |ct|
          unless runs[[ct[:pool], ct[:id]]] == init_start_time(ct[:init_pid])
            raise InvalidSample, 'run_changed'
          end
        end

        { started:, inventory:, cpu:, memory:, loadavg:, runs:, measurements:, loads: }
      ensure
        client.close
      end
    end

    def read_inventory(client)
      rows = client.cmd_data!(:ct_list, state: ['running'], read_hostname: false)
      raise InvalidSample, 'invalid_inventory' unless rows.is_a?(Array)

      rows = rows.map do |ct|
        unless ct.is_a?(Hash) && ct[:state] == 'running' &&
               %i[pool id group_path].all? { |k| ct[k].is_a?(String) && !ct[k].empty? } &&
               ct[:init_pid].is_a?(Integer) && ct[:init_pid] > 0
          raise InvalidSample, 'invalid_inventory'
        end

        ct.slice(:pool, :id, :group_path, :state, :init_pid)
      end.sort_by { |ct| [ct[:pool], ct[:id]] }
      identities = rows.map { |ct| [ct[:pool], ct[:id]] }
      raise InvalidSample, 'invalid_inventory' if identities.uniq.length != identities.length

      rows
    end

    def init_start_time(pid)
      stat = File.read("/proc/#{pid}/stat")
      closing = stat.rindex(')')
      raise InvalidSample, 'invalid_run' unless closing && stat.split.first == pid.to_s

      fields = stat[closing + 1..].split
      start = Integer(fields.fetch(19), 10)
      raise InvalidSample, 'invalid_run' if start < 0 || %w[Z X x].include?(fields[0])

      start
    rescue ArgumentError, IndexError
      raise InvalidSample, 'invalid_run'
    end

    def read_cpu
      values = File.open('/proc/stat', &:readline).split
      raise InvalidSample, 'invalid_host_cpu' unless values.shift == 'cpu' && values.length >= 10

      counters = values.take(10).map { |v| Integer(v, 10) }
      raise InvalidSample, 'invalid_host_cpu' if counters.any? { |v| v < 0 }

      Top::Host::Cpu.new(*counters)
    rescue ArgumentError
      raise InvalidSample, 'invalid_host_cpu'
    end

    def read_memory
      mem = OsCtl::Lib::MemInfo.new
      {
        total: mem.total, used: mem.used, free: mem.free, buffers: mem.buffers,
        cached: mem.cached, swap_total: mem.swap_total, swap_used: mem.swap_used,
        swap_free: mem.swap_free
      }.transform_values do |value|
        raise InvalidSample, 'invalid_memory' unless nonnegative?(value)

        value * 1024
      end
    end

    def valid_load(values)
      unless values.is_a?(Array) && values.length == 3 && values.all? { |v| nonnegative?(v) }
        raise InvalidSample, 'invalid_load'
      end

      values
    end

    def nonnegative?(value)
      value.is_a?(Numeric) && value.finite? && value >= 0
    end

    def validate_measurement(measurement)
      values = measurement.data
      unless !measurement.failed_limit_read && %i[cpu_user_hz cpu_system_hz memory].all? { |k| nonnegative?(values[k]) }
        raise InvalidSample, 'missing_cgroup_value'
      end

      COUNTERS.each do |k|
        raise InvalidSample, 'invalid_cpu_counter' if values.has_key?(k) && !nonnegative?(values[k])
      end
      %i[memory_limit cpu_limit].each do |k|
        next if values[k].nil?
        next if nonnegative?(values[k]) && values[k] > 0

        raise InvalidSample, 'invalid_limit'
      end
    end

    def delta_error(raw, previous)
      return 'initial_baseline' unless previous
      return 'run_changed' unless raw[:inventory] == previous[:inventory] && raw[:runs] == previous[:runs]
      return 'invalid_window' unless raw[:cpu].time > previous[:cpu].time
      return 'counter_reset' if raw[:cpu].each_pair.any? { |k, v| v < previous[:cpu][k] }

      raw[:measurements].each do |key, measurement|
        old = previous[:measurements][key]
        return 'invalid_window' unless measurement.time > old.time
        return 'counter_reset' if COUNTERS.any? { |k| old.data[k] && measurement.data[k] < old.data[k] }
      end
      cpu = raw[:cpu].diff(previous[:cpu])
      return 'invalid_host_cpu_delta' unless nonnegative?(cpu.total) && cpu.total > 0

      nil
    end

    def metadata(started, completed, complete, reason, window_start)
      {
        oomd_schema: 1, epoch: @epoch, sequence: @sequence,
        sample_started_monotonic_ns: started, sample_completed_monotonic_ns: completed,
        measurement_window_started_monotonic_ns: window_start,
        measurement_window_completed_monotonic_ns: completed,
        complete:, invalid_reason: reason
      }
    end

    def project(raw, previous, reason)
      cpu = previous && !reason ? raw[:cpu].diff(previous[:cpu]) : nil
      sum_cpu = 0
      sum_memory = 0
      rows = raw[:inventory].map do |ct|
        key = [ct[:pool], ct[:id]]
        measurement = raw[:measurements][key]
        values = measurement.data
        usage = nil
        if cpu
          delta = measurement.diff_from(previous[:measurements][key], :realtime)
          hz = delta[:cpu_user_hz] + delta[:cpu_system_hz]
          sum_cpu += hz
          usage = calc_cpu_usage(hz, cpu.total)
        end
        sum_memory += values[:memory]
        {
          pool: ct[:pool], id: ct[:id], init_pid: ct[:init_pid],
          init_start_time_ticks: raw[:runs][key], loadavg: raw[:loads]["#{ct[:pool]}:#{ct[:id]}"].averages,
          memory: values[:memory], memory_limit: values[:memory_limit],
          cpu_limit: values[:cpu_limit], cpu_usage: usage, valid: reason.nil?, invalid_reason: reason
        }
      end
      rows << {
        pool: nil, id: '[host]', init_pid: nil, init_start_time_ticks: nil,
        loadavg: raw[:loadavg], memory: [raw[:memory][:used] - sum_memory, 0].max,
        memory_limit: nil, cpu_limit: nil,
        cpu_usage: cpu && calc_cpu_usage(cpu.total_used - sum_cpu, cpu.total),
        valid: reason.nil?, invalid_reason: reason
      }

      metadata(raw[:started], raw[:completed], reason.nil?, reason, previous && previous[:started]).merge(
        cpu: cpu && calc_host_cpu_usage(cpu), loadavg: raw[:loadavg], memory: raw[:memory], containers: rows
      )
    end

    def invalid_frame(started, completed, reason)
      metadata(started, completed, false, reason, nil).merge(
        cpu: nil, loadavg: nil, memory: nil,
        containers: [{ pool: nil, id: '[host]', init_pid: nil, init_start_time_ticks: nil,
                       loadavg: nil, memory: nil, memory_limit: nil, cpu_limit: nil,
                       cpu_usage: nil, valid: false, invalid_reason: reason }]
      )
    end
  end
end
