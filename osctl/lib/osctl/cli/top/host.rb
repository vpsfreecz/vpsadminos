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

    def initialize
      super(id: '[host]', pool: nil, group_path: '', state: 'running')
      @cpu = []
    end

    def running?
      true
    end

    def container?
      false
    end

    def measure(subsystems)
      super
      measure_host_cpu_hz
    end

    def result(mode)
      ret = super

      # root pids cgroup does not have process counter
      ret[:nproc] = `ps axh -opid | wc -l`.strip.to_i
      ret
    end

    def cpu_result
      @cpu[1].diff(@cpu[0])
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
  end
end
