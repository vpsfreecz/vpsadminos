require 'singleton'
require 'libosctl'
require 'osctld/run_state'

module OsCtld
  # Schedule containers on CPUs to keep them running on the same package
  class CpuScheduler
    STATE_FILE = File.join(RunState::CPU_SCHEDULER_DIR, 'state.yml')

    include Singleton
    include Lockable

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::File

    class << self
      %i(
        assets
        setup
        shutdown
        enabled?
        needed?
        use?
        enable
        disable
        enable_package
        disable_package
        schedule_ct
        unschedule_ct
        upkeep
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
      :usage_score,
      :container_count,
      :enabled,
      keyword_init: true,
    )

    ScheduleInfo = Struct.new(
      :ctid,
      :usage_score,
      :package_id,
      keyword_init: true,
    )

    def initialize
      init_lock

      @enabled = Daemon.get.config.enable_cpu_scheduler?
      @min_package_container_count_percent = Daemon.get.config.cpu_scheduler_min_package_container_count_percent
      @upkeep_queue = OsCtl::Lib::Queue.new
      @save_queue = OsCtl::Lib::Queue.new
      @topology = OsCtl::Lib::CpuTopology.new
      @control_mutex = Mutex.new
      @package_info = {}
      @scheduled_cts = {}

      topology.packages.each_value do |pkg|
        @package_info[pkg.id] = PackageInfo.new(
          id: pkg.id,
          cpuset: pkg.cpus.keys.sort.join(','),
          usage_score: 0,
          container_count: 0,
          enabled: true,
        )
      end

      log(:info, "#{topology.cpus.length} CPUs in #{topology.packages.length} packages")
    end

    def assets(add)
      add.directory(
        RunState::CPU_SCHEDULER_DIR,
        desc: 'CPU scheduler state files',
        user: 0,
        group: 0,
        mode: 0755,
      )
      add.file(
        STATE_FILE,
        desc: 'CPU scheduler state file',
        user: 0,
        group: 0,
        mode: 0400,
        optional: true,
      )
    end

    def setup
      load_state

      @save_thread = Thread.new { run_save }

      start_upkeep if use?
    end

    def shutdown
      sync_control do
        stop_upkeep

        if save_thread
          @do_shutdown = true
          save_queue << :save
          save_thread.join
          @save_thread = nil
        end
      end
    end

    # Enable and start the scheduler
    def enable
      exclusively do
        @enabled = true
      end

      sync_control do
        start_upkeep unless upkeep_running?
      end
    end

    # Disable and stop the scheduler
    def disable
      exclusively do
        @enabled = false
      end

      sync_control { stop_upkeep }
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

      exclusively do
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

      exclusively do
        next unless package_info.has_key?(package_id)

        package_info[package_id].enabled = false
        ret = true
      end

      ret
    end

    # Assign container to an available CPU package and configure its cpuset
    # @param ctrc [Container::RunConfiguration]
    def schedule_ct(ctrc)
      sched = do_schedule_ct(ctrc)
      ctrc.save if sched
      nil
    end

    # Remove container from the scheduler
    # @param ct [Container]
    def unschedule_ct(ct)
      exclusively do
        sched = scheduled_cts.delete(ct.ident)
        return if sched.nil?

        pkg = package_info[sched.package_id]
        pkg.container_count -= 1
        pkg.usage_score -= sched.usage_score
      end

      nil
    end

    def upkeep
      sync_control do
        upkeep_queue << :upkeep if upkeep_running?
      end
    end

    def export_status
      ret = {}

      exclusively do
        ret.update(enabled: enabled?, needed: needed?, use: use?)
      end

      sync_control do
        ret.update(upkeep_running: upkeep_running?)
      end

      ret[:packages] = topology.packages.length
      ret[:cpus] = topology.cpus.length

      ret
    end

    def export_packages
      exclusively do
        topology.packages.each_value.map do |pkg|
          {
            id: pkg.id,
            cpus: pkg.cpus.keys,
            containers: package_info[pkg.id].container_count,
            usage_score: package_info[pkg.id].usage_score,
            enabled: package_info[pkg.id].enabled,
          }
        end
      end
    end

    def log_type
      'cpu-scheduler'
    end

    protected
    attr_reader :topology, :package_info, :scheduled_cts,
      :upkeep_thread, :upkeep_queue, :save_thread, :save_queue

    # Start background container upkeeping
    def start_upkeep
      sync_control do
        @upkeep_thread = Thread.new { run_upkeep }
      end
    end

    # Stop background container upkeeping
    def stop_upkeep
      sync_control do
        return unless upkeep_running?

        upkeep_queue << :stop
        upkeep_thread.join
        @upkeep_thread = nil
      end
    end

    # Return `true` if the scheduler is running
    def upkeep_running?
      sync_control { !@upkeep_thread.nil? }
    end

    def do_schedule_ct(ctrc)
      daily_use = ctrc.ct.hints.cpu_daily.usage_us
      pkg = nil
      sched = nil

      exclusively do
        return unless use?

        pkg =
          if daily_use == 0 || !can_schedule_by_score?
            # no usage stats available, choose package based on number of cts
            get_package_by_count(daily_use)
          else
            # choose package based on cpu use
            get_package_by_score(daily_use)
          end

        if pkg.nil?
          log(:warn, "No enabled package found, unable to schedule #{ctrc.ident}")
          return
        end

        sched = record_scheduled(ctrc.ct, daily_use, pkg)
      end

      save_state

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
      sched
    end

    # We can schedule by score if no package has less than 75 % cts of the most-used package
    def can_schedule_by_score?
      max_cnt = nil
      min_cnt = nil

      package_info.each_value do |pkg|
        max_cnt = pkg.container_count if max_cnt.nil? || max_cnt < pkg.container_count
        min_cnt = pkg.container_count if min_cnt.nil? || min_cnt > pkg.container_count
      end

      (min_cnt.to_f / max_cnt) * 100 >= @min_package_container_count_percent
    end

    def get_package_by_count(usage_score)
      sorted_pkgs = package_info.values.select(&:enabled).sort do |a, b|
        a.container_count <=> b.container_count
      end

      pkg = sorted_pkgs.first
      return if pkg.nil?

      pkg.container_count += 1
      pkg.usage_score += usage_score
      pkg
    end

    def get_package_by_score(usage_score)
      sorted_pkgs = package_info.values.select(&:enabled).sort do |a, b|
        a.usage_score <=> b.usage_score
      end

      pkg = sorted_pkgs.first
      return if pkg.nil?

      pkg.container_count += 1
      pkg.usage_score += usage_score
      pkg
    end

    def record_scheduled(ct, usage_score, pkg)
      if scheduled_cts[ct.ident]
        # This container has already been scheduled, so fix the leak
        sched = scheduled_cts[ct.ident]
        sched_pkg = package_info[ sched.package_id ]

        log(:warn, "Fixing schedule leak for #{ct.ident}: scheduling on #{pkg.id}, while already scheduled on #{sched_pkg.id}")

        sched_pkg.usage_score -= sched.usage_score
        sched_pkg.container_count -= 1
      end

      scheduled_cts[ct.ident] = ScheduleInfo.new(
        ctid: ct.ident,
        usage_score: usage_score,
        package_id: pkg.id,
      )
    end

    def run_upkeep
      loop do
        v = upkeep_queue.pop(timeout: 60*5)
        return if v == :stop

        cts = DB::Containers.get.each do |ct|
          ctrc = ct.run_conf
          stopped = ct.state == :stopped

          exclusively do
            sched = scheduled_cts[ct.ident]

            if stopped && ctrc.nil? && sched
              unschedule_ct(ct)
            elsif ctrc && ctrc.cpu_package.nil? && sched
              unschedule_ct(ct)
            elsif ctrc && ctrc.cpu_package && ctrc.cpu_package != sched.package_id
              record_scheduled(ct, ct.hints.cpu_daily.usage_us, package_info[ctrc.cpu_package])
            end
          end
        end

        save_state
      end
    end

    def run_save
      loop do
        v = save_queue.pop
        return if v == :stop

        do_save_state
        return if @do_shutdown

        sleep(1)
      end
    end

    def dump_scheduled
      ret = []

      inclusively do
        scheduled_cts.each do |id, sched|
          ret << {
            'ctid' => id,
            'usage_score' => sched.usage_score,
            'package_id' => sched.package_id,
          }
        end
      end

      {'scheduled_cts' => ret}
    end

    def save_state
      save_queue << :save
    end

    def do_save_state
      data = dump_scheduled

      regenerate_file(STATE_FILE, 0400) do |new|
        new.write(OsCtl::Lib::ConfigFile.dump_yaml(data))
      end

      File.chown(0, 0, STATE_FILE)
    end

    def load_state
      begin
        data = OsCtl::Lib::ConfigFile.load_yaml_file(STATE_FILE)
      rescue Errno::ENOENT
        return
      end

      data.fetch('scheduled_cts', []).each do |ct|
        sched = ScheduleInfo.new(
          ctid: ct['ctid'],
          usage_score: ct['usage_score'],
          package_id: ct['package_id'],
        )

        next unless package_info.has_key?(sched.package_id)

        scheduled_cts[sched.ctid] = sched

        pkg = package_info[sched.package_id]
        pkg.container_count += 1
        pkg.usage_score += sched.usage_score
      end
    end

    def sync_control(&block)
      if @control_mutex.owned?
        block.call
      else
        @control_mutex.synchronize(&block)
      end
    end
  end
end
