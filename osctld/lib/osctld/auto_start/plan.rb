require 'libosctl'
require 'etc'

module OsCtld
  class AutoStart::Plan
    include OsCtl::Lib::Utils::Log

    attr_reader :pool

    def initialize(pool)
      @pool = pool
      @plan = ContinuousExecutor.new(pool.parallel_start)
      @state = AutoStart::State.load(pool)
      @reboot = AutoStart::Reboot.load(pool)
      @stop = false
      @nproc = Etc.nprocessors
    end

    def assets(add)
      state.assets(add)
      reboot.assets(add)
    end

    def start(force: false)
      @stop = false

      log(
        :info,
        "Auto-starting containers, #{pool.parallel_start} containers at a time"
      )

      # Select containers for autostart
      cts = DB::Containers.get.select do |ct|
        next(false) if ct.pool != pool
        next(true) if reboot.include?(ct) && ct.can_start?
        next(true) if ct.autostart && ct.can_start? && (force || !state.is_started?(ct))

        next(false)
      end

      log(:info, "#{cts.size} containers to start")

      # Preschedule the containers
      if CpuScheduler.use?
        cts.reject do |ct|
          ct.running?
        end.sort do |a, b|
          b.hints.cpu_daily.usage_us <=> a.hints.cpu_daily.usage_us
        end.each do |ct|
          CpuScheduler.preschedule_ct(ct)
        end
      end

      # Start the containers
      #
      # If the CPU scheduler is in use, we want to start containers from the
      # second CPU package first. {CpuScheduler.preschedule_ct} already put
      # prioritized containers to the second package.
      start_cts =
        if CpuScheduler.use_sequential_start_stop?
          log(:info, 'Using sequential auto-start')

          cts.sort do |a, b|
            a_package = CpuScheduler.get_preschedule_package_id(a)
            b_package = CpuScheduler.get_preschedule_package_id(b)

            # Start containers with a CPU package first
            if a_package && !b_package
              -1
            elsif !a_package && b_package
              1

            # Neither container has CPU package, sort by start priority
            elsif !a_package && !b_package
              a.autostart <=> b.autostart

            # Same CPU package, sort by start priority
            elsif a_package == b_package
              a.autostart <=> b.autostart

            # Sort by CPU package, higher package first
            else
              b_package <=> a_package
            end
          end.each_with_index
        else
          log(:info, 'Using priority auto-start')
          cts
        end

      debug = Daemon.get.config.debug?

      if debug
        counter = 1 # we cannot use i, because it is used only for sequential auto-start
        total = start_cts.size
      end

      plan << (start_cts.map do |ct, i|
        if debug
          log(
            :debug,
            "[#{counter.to_s.rjust(4)}/#{total}] #{ct.id} priority=#{ct.autostart.priority} cpu-package=#{CpuScheduler.get_preschedule_package_id(ct) || '-'}"
          )
          counter += 1
        end

        ContinuousExecutor::Command.new(
          id: ct.id,
          priority: i || ct.autostart.priority
        ) do |cmd|
          cur_ct = DB::Containers.find(cmd.id, pool)

          if cur_ct.nil? || !cur_ct.can_start?
            CpuScheduler.cancel_preschedule_ct(ct)
            next
          elsif cur_ct.running?
            CpuScheduler.cancel_preschedule_ct(ct)
            state.set_started(cur_ct)
            next
          end

          prestart_delay(cur_ct)
          log(:info, cur_ct, 'Auto-starting container')
          do_try_start_ct(cur_ct)
        end
      end)
    end

    def enqueue(ct, priority: 10, start_opts: {})
      plan << (
        ContinuousExecutor::Command.new(id: ct.id, priority:) do |cmd|
          cur_ct = DB::Containers.find(cmd.id, pool)
          next if cur_ct.nil? || cur_ct.running?

          prestart_delay(cur_ct)
          log(:info, ct, 'Starting enqueued container')
          do_try_start_ct(
            cur_ct,
            start_opts: start_opts.merge(queue: false)
          )
        end
      )
    end

    def start_ct(ct, priority: 10, start_opts: {}, client_handler: nil)
      plan.execute(
        ContinuousExecutor::Command.new(id: ct.id, priority:) do |cmd|
          cur_ct = DB::Containers.find(cmd.id, pool)
          next if cur_ct.nil? || cur_ct.running?

          prestart_delay(cur_ct)
          log(:info, ct, 'Starting enqueued container')
          Commands::Container::Start.run(
            **start_opts.merge(
              pool: cur_ct.pool.name,
              id: cur_ct.id,
              queue: false,
              internal: { handler: client_handler }
            )
          )
        end,
        timeout: start_opts ? (start_opts[:wait] || Container::DEFAULT_START_TIMEOUT) : nil
      )
    end

    def request_reboot(ct)
      reboot.add(ct)
    end

    def fulfil_reboot(ct)
      reboot.clear(ct)
    end

    def stop_ct(ct)
      plan.remove(ct.id)
    end

    def clear_ct(ct)
      state.clear(ct)
      reboot.clear(ct)
    end

    def clear
      plan.clear
    end

    def resize(new_size)
      plan.resize(new_size)
    end

    def stop
      @stop = true
      plan.stop
    end

    def queue
      plan.queue
    end

    def log_type
      "#{pool.name}:auto-start"
    end

    protected

    attr_reader :plan, :state, :reboot

    def do_try_start_ct(ct, attempts: 5, cooldown: 5, start_opts: {})
      attempts.times do |i|
        return if stop?

        ret = Commands::Container::Start.run(**start_opts.merge(
          pool: ct.pool.name,
          id: ct.id,
          wait: 'infinity'
        ))

        if ret[:status]
          state.set_started(ct)
          return if stop?

          if delay_after_start?
            log(:info, ct, "Autostart delay for #{ct.autostart.delay} seconds")
            sleep(ct.autostart.delay)
          else
            log(:info, ct, 'Skipping autostart delay thanks to low system load average')
          end

          return
        end

        if i + 1 == attempts
          log(:warn, ct, 'All attempts to start the container have failed')
          return
        end

        if stop?
          log(:warn, ct, 'Unable to start the container, giving up to stop')
          return
        else
          pause = cooldown + (i * cooldown)
          log(:warn, ct, "Unable to start the container, retrying in #{pause} seconds")
          sleep(pause)
        end
      end
    end

    def prestart_delay(ct)
      delay = rand(0.0..3.0)
      log(:info, ct, "Delaying auto-start by #{delay.round(2)}s")
      sleep(delay)
    end

    def delay_after_start?
      lavg = OsCtl::Lib::LoadAvg.new
      lavg.avg[1] >= @nproc
    end

    def stop?
      @stop
    end
  end
end
