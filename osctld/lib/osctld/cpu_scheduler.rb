require 'singleton'
require 'libosctl'

module OsCtld
  # Schedule containers on CPUs to keep them running on the same package
  class CpuScheduler
    include Singleton
    include Lockable

    include OsCtl::Lib::Utils::Log

    class << self
      %i(
        enabled?
        needed?
        use?
        start
        stop
        enable
        disable
        enable_package
        disable_package
        running?
        schedule_ct
        export_status
        export_packages
      ).each do |v|
        define_method(v) do |*args, **kwargs|
          instance.send(v, *args, **kwargs)
        end
      end
    end

    PackageInfo = Struct.new(
      :id,
      :cpuset,
      :idle,
      :enabled,
      :last_check,
      keyword_init: true,
    )

    def initialize
      init_lock

      @enabled = Daemon.get.config.enable_cpu_scheduler?
      @queue = OsCtl::Lib::Queue.new
      @topology = OsCtl::Lib::CpuTopology.new
      @package_mutex = Mutex.new
      @package_info = {}

      topology.packages.each_value do |pkg|
        @package_info[pkg.id] = PackageInfo.new(
          id: pkg.id,
          cpuset: pkg.cpus.keys.sort.join(','),
          idle: 0,
          enabled: true,
          last_check: nil,
        )
      end

      log(:info, "#{topology.cpus.length} CPUs in #{topology.packages.length} packages")
    end

    # Start background CPU monitoring
    def start
      exclusively do
        @thread = Thread.new { monitor_cpu_packages }
      end
    end

    # Stop CPU monitoring
    def stop
      exclusively do
        return unless running?

        queue << :stop
        thread.join
        @thread = nil
      end
    end

    # Enable and start the scheduler
    def enable
      exclusively do
        @enabled = true
        start unless running?
      end
    end

    # Disable and stop the scheduler
    def disable
      exclusively do
        @enabled = false
        stop
      end
    end

    # Return `true` if the scheduler is running
    def running?
      inclusively { !@thread.nil? }
    end

    # Return `true` if the scheduler is enabled by configuration
    def enabled?
      inclusively { @enabled }
    end

    # Return `true` if the scheduler is needed by the system
    def needed?
      topology.packages.length > 1
    end

    # Return `true` if the scheduler is both enabled and needed
    def use?
      inclusively { enabled? && needed? }
    end

    # @param package_id [Integer]
    # @return [Boolean]
    def enable_package(package_id)
      ret = false

      sync_pkg do
        next unless package_info.has_key?(package_id)

        package_info[package_id].enabled = true
        ret = true
      end

      ret
    end

    # @param package_id [Integer]
    # @return [Boolean]
    def disable_package(package_id)
      ret = false

      sync_pkg do
        next unless package_info.has_key?(package_id)

        package_info[package_id].enabled = false
        ret = true
      end

      ret
    end

    # Assign container to an available CPU package and configure its cpuset
    # @param ctrc [Container::RunConfiguration]
    def schedule_ct(ctrc)
      if use?
        do_schedule_ct(ctrc)
        queue << :wakeup
      end
    end

    def export_status
      ret = {}

      exclusively do
        ret.update(enabled: enabled?, needed: needed?, use: use?, running: running?)
      end

      ret[:packages] = topology.packages.length
      ret[:cpus] = topology.cpus.length

      ret
    end

    def export_packages
      pkg_cts = Hash[topology.packages.each_key.map { |pkg_id| [pkg_id, 0] }]

      DB::Containers.get.each do |ct|
        rc = ct.run_conf
        pkg_cts[rc.cpu_package] += 1 if rc && rc.cpu_package
      end

      sync_pkg do
        topology.packages.each_value.map do |pkg|
          {
            id: pkg.id,
            cpus: pkg.cpus.keys,
            containers: pkg_cts[pkg.id],
            idle: package_info[pkg.id].idle,
            enabled: package_info[pkg.id].enabled,
            last_check: package_info[pkg.id].last_check,
          }
        end
      end
    end

    def log_type
      'cpu-scheduler'
    end

    protected
    attr_reader :topology, :package_info, :thread, :queue

    def do_schedule_ct(ctrc)
      fail 'programming error: the scheduler is not running' unless running?

      sorted_pkgs = inclusively do
        package_info.values.sort do |a, b|
          b.idle <=> a.idle
        end
      end

      pkg = sorted_pkgs.detect { |pkg| pkg.enabled }

      if pkg.nil?
        log(:warn, "No enabled package found, unable to schedule #{ctrc.ident}")
        return
      end

      log(:info, "Assigning #{ctrc.ident} to CPU package #{pkg.id}")

      # cpuset cannot be configured when child groups already exists, so set it
      # as soon as possible.
      CGroup.mkpath('cpuset', ctrc.ct.base_cgroup_path.split('/'))
      package_set = CGroup.set_param(
        File.join(CGroup.abs_cgroup_path('cpuset', ctrc.ct.base_cgroup_path), 'cpuset.cpus'),
        [pkg.cpuset]
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
        value: [pkg.cpuset],
        persistent: false,
      )])

      ctrc.cpu_package = pkg.id
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
      now = Time.now
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

      sync_pkg do
        new_idle.each do |pkg_id, idle|
          package_info[pkg_id].idle = idle
          package_info[pkg_id].last_check = now
        end
      end
    end

    def sync_pkg(&block)
      @package_mutex.synchronize(&block)
    end
  end
end
