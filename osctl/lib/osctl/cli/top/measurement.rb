require 'libosctl'
require 'osctl/cli/cgroup_params'

module OsCtl::Cli
  class Top::Measurement
    class Error < StandardError; end

    include CGroupParams

    attr_reader :time, :monotonic_ns, :data, :core_error, :required_read_failed, :netif_sources, :dataset_source

    def initialize(host, subsystems, group_path, dataset, netifs, enable_netif: true, enable_zfs: true)
      @host = host
      @subsystems = subsystems
      @group_path = group_path
      @dataset = dataset
      @netifs = netifs
      @data = {}
      @enable_netif = enable_netif
      @enable_zfs = enable_zfs
    end

    CORE_FIELDS = %i[cpu_us cpu_hz cpu_limit memory memory_limit nproc].freeze

    def measure(clock:)
      @time = Time.now
      @monotonic_ns = clock.call
      cg_reader = OsCtl::Lib::CGroup::PathReader.new(subsystems, group_path)

      # One reader/cache per group. A failed gauge must not abort the other
      # reads, and a successfully omitted limit means known unlimited.
      CORE_FIELDS.each do |field|
        data.update(cg_reader.read_stats([field], true))
      rescue StandardError
        @required_read_failed = true
        data[field] = nil
      end
      @limit_states = %i[cpu_limit memory_limit].to_h do |key|
        value = data[key]
        [key, if !data.has_key?(key)
                'unlimited'
              elsif nonnegative?(value) && raw(value) > 0
                'limited'
              else
                'unknown'
              end]
      end

      validate_core
      data[:cpu_limit] = nil unless data.has_key?(:cpu_limit)
      data[:memory_limit] = nil unless data.has_key?(:memory_limit)

      data[:zfsio] = nil
      if @enable_zfs
        begin
          add_zfs_io_stats
        rescue StandardError
          data[:zfsio] = nil
        end
      end

      data[:tx] = data[:rx] = nil
      if @enable_netif
        begin
          data.update(verified_netif_stats)
        rescue StandardError
          data[:tx] = data[:rx] = nil
        end
      end
    rescue SystemCallError => e
      raise Error, e.message
    end

    def limit_state(key)
      @limit_states.fetch(key)
    end

    def delta_error(other)
      return 'invalid_window' unless time > other.time

      counter_error(other)
    end

    def counter_error(other)
      %i[cpu_us cpu_user_us cpu_system_us cpu_hz cpu_user_hz cpu_system_hz].each do |key|
        next if data[key].nil? || other.data[key].nil?
        return 'counter_reset' if raw(data[key]) < raw(other.data[key])
      end
      nil
    end

    protected

    attr_reader :host, :subsystems, :group_path, :dataset, :netifs

    def raw(value)
      value.is_a?(OsCtl::Lib::Cli::Presentable) ? value.raw : value
    end

    def nonnegative?(value)
      value = raw(value)
      value.is_a?(Numeric) && value.finite? && value >= 0
    end

    def validate_core
      @core_error = nil
      unless %i[cpu_user_hz cpu_system_hz memory].all? { |k| nonnegative?(data[k]) }
        @core_error = 'missing_cgroup_value'
      end
      %i[cpu_limit memory_limit].each do |k|
        next unless data.has_key?(k)

        if data[k].nil?
          @core_error = 'missing_cgroup_value'
        elsif !nonnegative?(data[k]) || raw(data[k]) <= 0
          @core_error = 'invalid_limit'
        end
      end
    end

    def verified_netif_stats
      reading = host.netif_stats
      names = netifs == :all ? reading.list_netifs : netifs.filter_map(&:veth)
      ret = { tx: { bytes: 0, packets: 0 }, rx: { bytes: 0, packets: 0 } }
      sources = names.sort.map do |name|
        identity, stats = reading.verified_stats(name)
        raise Error, 'unavailable network interface' unless identity && stats

        ret.each do |dir, counters|
          source_dir = dir
          source_dir = dir == :tx ? :rx : :tx unless netifs == :all
          counters.each_key { |kind| counters[kind] += stats.fetch(source_dir).fetch(kind) }
        end
        [name, identity]
      end
      @netif_sources = sources
      ret
    end

    def add_zfs_io_stats
      source = netifs == :all ? host.objsets : (dataset && host.objsets[dataset])
      return unless source

      @dataset_source = source.source_id if dataset
      stats = source.aggregate_stats
      data[:zfsio] = {
        ios: { w: stats.write_ios, r: stats.read_ios },
        bytes: { w: stats.write_bytes, r: stats.read_bytes }
      }
    end
  end
end
