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
        preschedule_ct
        cancel_preschedule_ct
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
      :reservation,
      :reserved_at,
      keyword_init: true,
    )

    def initialize
      init_lock

      @enabled = Daemon.get.config.cpu_scheduler.enable?
      @min_package_container_count_percent = Daemon.get.config.cpu_scheduler.min_package_container_count_percent
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

    # Make a reservation in the scheduler
    # @param ct [Container]
    def preschedule_ct(ct)
      assign_package_for(ct, reservation: true)
    end

    # Cancel a reservation in the scheduler
    # @param ct [Container]
    def cancel_preschedule_ct(ct)
      exclusively do
        sched = scheduled_cts[ct.ident]
        return if sched.nil? || !sched.reservation

        scheduled_cts.delete(ct.ident)

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
      pkg, sched = assign_package_for(ctrc.ct)
      return if pkg.nil?

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

      Eventd.report(
        :ct_scheduled,
        pool: ctrc.pool.name,
        id: ctrc.id,
        cpu_package_inuse: pkg.id,
      )

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

    def assign_package_for(ct, reservation: false)
      ct_pkg = ct.cpu_package
      wanted_pkg_id = nil
      daily_use = ct.hints.cpu_daily.usage_us
      pkg = nil
      sched = nil

      if ct_pkg == 'auto'
        # pass
      elsif ct_pkg == 'none'
        log(:info, "#{ct.ident} has disabled scheduler by config")
        return
      elsif !topology.packages.has_key?(ct_pkg)
        log(
          :warn,
          "#{ct.ident} prefers package #{ct_pkg.inspect}, which does not "+
          "exist on this system; disregarding"
        )
      else
        wanted_pkg_id = ct_pkg
      end

      exclusively do
        return unless use?

        sched = scheduled_cts[ct.ident]

        if sched && sched.reservation
          sched.reservation = false
          sched.reserved_at = nil
          pkg = package_info[sched.package_id]

          log(:info, "Using reservation of #{ct.ident} on CPU package #{pkg.id}")
        else
          pkg =
            if wanted_pkg_id
              # static pin
              get_package_by_preference(wanted_pkg_id, daily_use)
            elsif daily_use == 0 || !can_schedule_by_score?
              # no usage stats available, choose package based on number of cts
              get_package_by_count(daily_use)
            else
              # choose package based on cpu use
              get_package_by_score(daily_use)
            end

          sched = record_scheduled(ct, reservation, daily_use, pkg) if pkg
        end

        if pkg.nil?
          log(:warn, "No enabled package found, unable to schedule #{ct.ident}")
          return
        end
      end

      save_state

      if reservation
        log(:info, "Preassigning #{ct.ident} to CPU package #{pkg.id}")
      else
        log(:info, "Assigning #{ct.ident} to CPU package #{pkg.id}")
      end

      [pkg, sched]
    end

    def get_package_by_preference(pkg_id, usage_score)
      pkg = package_info[pkg_id]
      pkg.container_count += 1
      pkg.usage_score += usage_score
      pkg
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

    def record_scheduled(ct, reservation, usage_score, pkg)
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
        reservation: reservation,
        reserved_at: reservation ? Time.now : nil,
      )
    end

    def run_upkeep
      unschedule_table = {}

      loop do
        v = upkeep_queue.pop(timeout: 60*5)
        return if v == :stop

        now = Time.now

        cts = DB::Containers.get.each do |ct|
          ctrc = ct.run_conf
          stopped = ct.state == :stopped
          should_unschedule = false

          exclusively do
            sched = scheduled_cts[ct.ident]

            if stopped && ctrc.nil? && sched
              if !sched.reservation || sched.reserved_at + 60*60 < now
                should_unschedule = true
              end
            elsif ctrc && ctrc.cpu_package.nil? && sched
              should_unschedule = true
            elsif ctrc && ctrc.cpu_package && (sched.nil? || ctrc.cpu_package != sched.package_id)
              pkg = package_info[ctrc.cpu_package]
              pkg.container_count += 1
              pkg.usage_score += ct.hints.cpu_daily.usage_us
              record_scheduled(ct, false, ct.hints.cpu_daily.usage_us, pkg)
            end

            if should_unschedule
              unschedule_table[ct.ident] ||= 0
              unschedule_table[ct.ident] += 1
              unschedule_ct(ct) if unschedule_table[ct.ident] > 3
            else
              unschedule_table.delete(ct.ident)
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
            'reservation' => sched.reservation,
            'reserved_at' => sched.reserved_at && sched.reserved_at.to_i,
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
          reservation: ct['reservation'],
          reserved_at: ct['reserved_at'] && Time.at(ct['reserved_at']),
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
