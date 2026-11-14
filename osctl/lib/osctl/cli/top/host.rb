require 'osctl/cli/top/container'
require 'libosctl'

module OsCtl::Cli
  class Top::Host < Top::Container
    Cpu = Struct.new(
      :user,
      :nice,
      :system,
      :idle,
      :iowait,
      :irq,
      :softirq,
      :steal,
      :guest,
      :guest_nice
    ) do
      attr_reader :time

      def initialize(*_)
        super
        @time = Time.now
      end

      def diff(other)
        ret = self.class.new
        delta = time - other.time

        other.each_pair do |k, v|
          ret[k] = (self[k] - v) / delta.to_f
        end

        ret
      end

      def total_used
        return @total_used if @total_used

        sum = 0

        each_pair do |k, v|
          next if k == :idle

          sum += v
        end

        @total_used = sum
      end

      def total
        return @total if @total

        @total = reduce(:+)
      end
    end

    attr_reader :pools, :objsets, :netif_stats

    # @param iostat_reader [OsCtl::Lib::Zfs::IOStat, nil]
    def initialize(iostat_reader, enable_netif: true, enable_zfs: true)
      super({ id: '[host]', pool: nil, group_path: '', state: 'running' },
            enable_netif:, enable_zfs:)
      @iostat_reader = iostat_reader
      @pools = []
      @cpu = []
      @zfs = []
      @objsets = nil
      @netifs = :all
      @netif_stats = enable_netif ? OsCtl::Lib::NetifStats.new : nil
    end

    def running?
      true
    end

    def container?
      false
    end

    def measure(subsystems)
      if @enable_netif
        begin
          @netif_stats ||= OsCtl::Lib::NetifStats.new
          netif_stats.reset
        rescue StandardError
          @netif_stats = nil
        end
      end
      if @enable_zfs
        begin
          measure_objsets
        rescue StandardError
          @objsets = nil
        end
      end
      super(self, subsystems)
      measure_host_cpu_hz
      measure_zfs if @enable_zfs
    end

    def result(mode, meminfo, lavg)
      ret = super(mode)

      # memory from the root cgroup does not account for all used memory
      ret[:memory] = meminfo.used * 1024

      ret[:nproc] = lavg.total

      ret
    end

    def cpu_result
      @cpu[1].diff(@cpu[0])
    end

    def zfs_result
      return nil unless @enable_zfs && @zfs.size == 2 && @zfs.all?

      diff_zfs(@zfs[1], @zfs[0])
    end

    def snapshot
      copy = super
      copy.instance_variable_set(:@cpu, @cpu.dup)
      copy.instance_variable_set(:@zfs, @zfs.dup)
      copy.instance_variable_set(:@pools, @pools.dup)
      copy
    end

    def reset_measurements(keep_current: false)
      super
      @cpu = keep_current && !@cpu.empty? ? [@cpu.last] : []
      @zfs = keep_current && !@zfs.empty? ? [@zfs.last] : []
    end

    def core_delta_error
      return 'initial_baseline' unless @cpu.size == 2
      return 'invalid_window' unless @cpu[-1].time > @cpu[-2].time
      return 'counter_reset' if @cpu[-1].each_pair.any? { |k, v| v < @cpu[-2][k] }

      total = cpu_result.total
      return 'invalid_host_cpu_delta' unless total.finite? && total > 0

      nil
    end

    protected

    attr_reader :iostat_reader

    def measure_host_cpu_hz
      values = File.open('/proc/stat', &:readline).split
      raise Top::Measurement::Error, 'invalid host CPU' unless values.shift == 'cpu' && values.size >= 10

      counters = values.take(10).map { |v| Integer(v, 10) }
      raise Top::Measurement::Error, 'invalid host CPU' if counters.any?(&:negative?)

      @cpu << Cpu.new(*counters)
      @cpu.shift if @cpu.size > 2
    end

    def measure_zfs
      begin
        @zfs << {
          arcstats: Top::ArcStats.new,
          iostat: iostat_reader && iostat_reader.current_all
        }
      rescue StandardError
        @zfs << nil
      end
      @zfs.shift if @zfs.size > 2
    end

    def measure_objsets
      @objsets = OsCtl::Lib::Zfs::ObjsetStats.read_pools(pools)
    end

    # @param current [Hash]
    # @param previous [Hash]
    def diff_zfs(current, previous)
      {
        arcstats: diff_arcstats(current[:arcstats], previous[:arcstats]),
        iostat: current[:iostat] && get_iostat(current[:iostat])
      }
    end

    # @param current [Top::ArcStats]
    # @param previous [Top::ArcStats]
    def diff_arcstats(current, previous)
      {
        arc: {
          c_max: current.c_max,
          c: current.c,
          size: current.size,
          hit_rate: current.hit_rate(previous),
          misses: current.misses(previous)
        },
        l2arc: {
          size: current.l2_size,
          asize: current.l2_asize,
          hit_rate: current.l2_hit_rate(previous),
          misses: current.l2_misses(previous)
        }
      }
    end

    def get_iostat(current)
      {
        io_read: current.io_read,
        io_written: current.io_written,
        bytes_read: current.bytes_read,
        bytes_written: current.bytes_written
      }
    end
  end
end
