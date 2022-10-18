require 'singleton'
require 'libosctl'

module OsCtld
  # Schedule containers on CPUs to keep them running on the same package
  class CpuScheduler
    include Singleton
    include Lockable

    include OsCtl::Lib::Utils::Log

    class << self
      %i(enabled? needed? use? start stop running? schedule_ct).each do |v|
        define_method(v) do |*args, **kwargs|
          instance.send(v, *args, **kwargs)
        end
      end
    end

    def initialize
      init_lock

      @queue = OsCtl::Lib::Queue.new
      @topology = OsCtl::Lib::CpuTopology.new
      @package_cpuset = {}
      @package_idle = {}

      topology.packages.each_value do |pkg|
        @package_cpuset[pkg.id] = pkg.cpus.keys.sort.join(',')
      end

      log(:info, "#{topology.cpus.length} CPUs in #{topology.packages.length} packages")
    end

    def start
      @thread = Thread.new { monitor_cpu_packages }
    end

    def stop
      return unless running?

      queue << :stop
      thread.join
      @thread = nil
    end

    # Return `true` if the scheduler is running
    def running?
      !@thread.nil?
    end

    # Return `true` if the scheduler is enabled by configuration
    def enabled?
      Daemon.get.config.enable_cpu_scheduler?
    end

    # Return `true` if the scheduler is needed by the system
    def needed?
      topology.packages.length > 1
    end

    # Return `true` if the scheduler is both enabled and needed
    def use?
      enabled? && needed?
    end

    # Assign container to an available CPU package and configure its cpuset
    # @param ctrc [Container::RunConfiguration]
    def schedule_ct(ctrc)
      if use?
        do_schedule_ct(ctrc)
        queue << :wakeup
      end
    end

    def log_type
      'cpu-scheduler'
    end

    protected
    attr_reader :topology, :package_cpuset, :package_idle, :thread, :queue

    def do_schedule_ct(ctrc)
      fail 'programming error: the scheduler is not running' unless running?

      pkg_id = inclusively do
        package_idle.sort do |a, b|
          b[1] <=> a[1]
        end.first[0]
      end

      log(:info, "Assigning #{ctrc.ident} to CPU package #{pkg_id}")

      cpu_mask = package_cpuset[pkg_id]

      # cpuset cannot be configured when child groups already exists, so set it
      # as soon as possible.
      CGroup.mkpath('cpuset', ctrc.ct.base_cgroup_path.split('/'))
      package_set = CGroup.set_param(
        File.join(CGroup.abs_cgroup_path('cpuset', ctrc.ct.base_cgroup_path), 'cpuset.cpus'),
        [cpu_mask]
      )

      # Even when we fail here, the cpuset configuration is propagated to LXC
      # config and it should still work.
      unless package_set
        log(:warn, "Unable to set cpuset for #{ctrc.ident}")
      end

      # To make sure that LXC also sets it, add it also among the container's
      # cgroup parameters.
      ctrc.ct.cgparams.set([CGroup::Param.import(
        subsystem: 'cpuset',
        parameter: 'cpuset.cpus',
        value: [cpu_mask],
        persistent: false,
      )])

      ctrc.cpu_package = pkg_id
      ctrc.save
    end

    def monitor_cpu_packages
      parse_proc_stat

      loop do
        v = queue.pop(timeout: 5)
        return if v == :stop

        parse_proc_stat
        sleep(1)
      end
    end

    def parse_proc_stat
      new_idle = Hash[topology.packages.map { |k, _| [k, 0] }]

      File.open('/proc/stat') do |f|
        f.each_line do |line|
          break unless line.start_with?('cpu')

          next unless /^cpu(\d+) / =~ line

          cpu_id = $1.to_i
          pkg_id = topology.cpus[cpu_id].package_id

          _name, _user, _nice, _system, idle, _ = line.split

          new_idle[pkg_id] += idle.to_i
        end
      end

      exclusively { @package_idle = new_idle }
    end
  end
end
