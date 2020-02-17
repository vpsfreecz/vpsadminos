require 'osctl/cli/top/container'

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

    attr_reader :pools, :objsets

    def initialize
      super(id: '[host]', pool: nil, group_path: '', state: 'running')
      @pools = []
      @cpu = []
      @zfs = []
      @objsets = nil
    end

    def running?
      true
    end

    def container?
      false
    end

    def measure(subsystems)
      measure_objsets
      super(self, subsystems)
      measure_host_cpu_hz
      measure_zfs
    end

    def result(mode, meminfo)
      ret = super(mode)

      # memory from the root cgroup does not account for all used memory
      ret[:memory] = meminfo.used * 1024

      # root pids cgroup does not have process counter
      ret[:nproc] = `ps axh -opid | wc -l`.strip.to_i

      ret
    end

    def cpu_result
      @cpu[1].diff(@cpu[0])
    end

    def zfs_result
      diff_zfs(@zfs[1], @zfs[0])
    end

    protected
    def measure_host_cpu_hz
      f = File.open('/proc/stat')
      str = f.readline
      f.close

      values = str.strip.split
      @cpu << Cpu.new(* values[1..-1].map(&:to_i))
      @cpu.shift if @cpu.size > 2
    end

    def measure_zfs
      @zfs << Top::ArcStats.new
      @zfs.shift if @zfs.size > 2
    end

    def measure_objsets
      @objsets = OsCtl::Lib::Zfs::ObjsetStats.read_pools(pools)
    end

    # @param current [Top::ArcStats]
    # @param previous [Top::ArcStats]
    def diff_zfs(current, previous)
      {
        arc: {
          c_max: current.c_max,
          c: current.c,
          size: current.size,
          hit_rate: current.hit_rate(previous),
          misses: current.misses(previous),
        },
        l2arc: {
          size: current.l2_size,
          asize: current.l2_asize,
          hit_rate: current.l2_hit_rate(previous),
          misses: current.l2_misses(previous),
        },
      }
    end
  end
end
