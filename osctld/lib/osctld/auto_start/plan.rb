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
      @shutdown = false
      @sleep_mutex = Mutex.new
      @sleep_cv = ConditionVariable.new
      @pending_intents = {}
      @nproc = Etc.nprocessors
    end

    def assets(add)
      state.assets(add)
      reboot.assets(add)
    end

    def start(force: false, activation: nil)
      unpause = proc do
        @sleep_mutex.synchronize do
          next false if @shutdown

          @stop = false
          true
        end
      end
      activated = activation ? activation.call(&unpause) : unpause.call
      return false unless activated

      log(
        :info,
        "Auto-starting containers, #{pool.parallel_start} containers at a time"
      )

      # Select containers for autostart
      cts = DB::Containers.get.select do |ct|
        next(false) if ct.pool != pool
        next(true) if reboot.include?(ct) && ct.can_start?

        lifecycle = ct.lifecycle
        next(true) if lifecycle.autostart_intent? && ct.can_start?

        daemon = Daemon.get
        next(true) if daemon.upgrade_handoff_desired?(ct) && ct.can_start?
        next(true) if ct.autostart && ct.can_start? && (force || !state.is_started?(ct))

        next(false)
      end

      log(:info, "#{cts.size} containers to start")

      # Preschedule the containers
      if CpuScheduler.use?
        cts.reject(&:running?).sort do |a, b|
          b.hints.cpu_daily.usage_us <=> a.hints.cpu_daily.usage_us
        end.each do |ct|
          CpuScheduler.preschedule_ct(ct)
        end
      end

      # Start the containers
      #
      # If the CPU scheduler is in use, we want to start containers from the
      # first CPU package first. {CpuScheduler.preschedule_ct} already put
      # prioritized containers to the first package.
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
              autostart_sort_key(a) <=> autostart_sort_key(b)

            # Same CPU package, sort by start priority
            elsif a_package == b_package # rubocop:disable Lint/DuplicateBranch
              autostart_sort_key(a) <=> autostart_sort_key(b)

            # Sort by CPU package, lower package first
            else
              a_package <=> b_package
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

      queued_starts = start_cts.filter_map do |ct, i|
        next if stop?

        request = persist_start_intent(ct)
        next if request == :skip
        next unless track_pending(ct, request)

        [ct, i, request]
      end

      plan << (queued_starts.map do |ct, i, request|
        if debug
          log(
            :debug,
            "[#{counter.to_s.rjust(4)}/#{total}] #{ct.id} priority=#{autostart_priority(ct)} cpu-package=#{CpuScheduler.get_preschedule_package_id(ct) || '-'}"
          )
          counter += 1
        end

        ContinuousExecutor::Command.new(
          id: ct.id,
          priority: i || autostart_priority(ct)
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
          do_try_start_ct(cur_ct, intent_id: request&.intent_id)
        ensure
          forget_pending(ct, request)
        end
      end)
    end

    def enqueue(ct, priority: 10, start_opts: {})
      request = persist_start_intent(ct, source: 'queued')
      return false if request == :skip
      return false unless track_pending(ct, request)

      plan << (
        ContinuousExecutor::Command.new(id: ct.id, priority:) do |cmd|
          cur_ct = DB::Containers.find(cmd.id, pool)
          next if cur_ct.nil? || cur_ct.running?

          prestart_delay(cur_ct)
          log(:info, ct, 'Starting enqueued container')
          do_try_start_ct(
            cur_ct,
            intent_id: request&.intent_id,
            start_opts: start_opts.merge(queue: false)
          )
        ensure
          forget_pending(ct, request)
        end
      )
      true
    end

    def start_ct(ct, priority: 10, start_opts: {}, client_handler: nil)
      request = persist_start_intent(ct, source: 'queued')
      return { status: false, message: 'container lifecycle start is blocked' } \
        if request == :skip
      return { status: false, message: 'container autostart queue is paused' } \
        unless track_pending(ct, request)

      plan.execute(
        ContinuousExecutor::Command.new(id: ct.id, priority:) do |cmd|
          cur_ct = DB::Containers.find(cmd.id, pool)
          next if cur_ct.nil? || cur_ct.running?

          prestart_delay(cur_ct)
          log(:info, ct, 'Starting enqueued container')
          Commands::Container::Start.run(
            **start_opts, pool: cur_ct.pool.name,
                          id: cur_ct.id,
                          queue: false,
                          lifecycle_intent_id: request&.intent_id,
                          lifecycle_source: 'queued',
                          internal: { handler: client_handler }
          )
        ensure
          forget_pending(ct, request)
        end,
        timeout: start_opts ? (start_opts[:wait] || Container::DEFAULT_START_TIMEOUT) : nil
      )
    end

    def fulfil_start(ct)
      state.set_started(ct)
    end

    def request_reboot(ct)
      reboot.add(ct)
    end

    def fulfil_reboot(ct)
      reboot.clear(ct)
    end

    def stop_ct(ct)
      plan.remove(ct.id)
      cancel_pending(ct:, preserve_desired: true)
    end

    def clear_ct(ct)
      state.clear(ct)
      reboot.clear(ct)
    end

    def clear
      plan.clear
      cancel_pending(preserve_desired: false)
    end

    # Stop admitting queued work without shutting down executor workers which
    # already own durable lifecycle generations.
    def pause
      @sleep_mutex.synchronize do
        @stop = true
        @sleep_cv.broadcast
      end
      plan.clear
      cancel_pending(preserve_desired: true)
    end

    def resume(activation: nil)
      return if @sleep_mutex.synchronize { @shutdown }

      start(activation:)
    end

    def resize(new_size)
      plan.resize(new_size)
    end

    def stop
      pause
      @sleep_mutex.synchronize { @shutdown = true }
      plan.stop
    end

    def started?
      @sleep_mutex.synchronize { !@shutdown }
    end

    def queue
      plan.queue
    end

    def log_type
      "#{pool.name}:auto-start"
    end

    protected

    attr_reader :plan, :state, :reboot

    def do_try_start_ct(ct, attempts: 5, cooldown: 5, start_opts: {}, intent_id: nil)
      attempts.times do |i|
        break if stop?

        ret = Commands::Container::Start.run(**start_opts, pool: ct.pool.name,
                                                           id: ct.id,
                                                           wait: 'infinity',
                                                           lifecycle_source: 'autostart',
                                                           lifecycle_intent_id: intent_id)

        if ret[:status]
          state.set_started(ct)
          break if stop?

          if delay_after_start?
            log(:info, ct, "Autostart delay for #{autostart_delay(ct)} seconds")
            interruptible_sleep(autostart_delay(ct))
          else
            log(:info, ct, 'Skipping autostart delay thanks to low system load average')
          end

          break
        end

        if i + 1 == attempts
          log(:warn, ct, 'All attempts to start the container have failed')
          break
        end

        if stop?
          log(:warn, ct, 'Unable to start the container, giving up to stop')
          break
        else
          pause = cooldown + (i * cooldown)
          log(:warn, ct, "Unable to start the container, retrying in #{pause} seconds")
          interruptible_sleep(pause)
        end
      end
    end

    def prestart_delay(ct)
      delay = rand(0.0..3.0)
      log(:info, ct, "Delaying auto-start by #{delay.round(2)}s")
      interruptible_sleep(delay)
    end

    def delay_after_start?
      lavg = OsCtl::Lib::LoadAvg.new
      lavg.avg[1] >= @nproc
    end

    def autostart_sort_key(ct)
      [autostart_priority(ct), ct.id]
    end

    def autostart_priority(ct)
      ct.autostart ? ct.autostart.priority : 10
    end

    def autostart_delay(ct)
      ct.autostart ? ct.autostart.delay : 0
    end

    def stop?
      @sleep_mutex.synchronize { @stop }
    end

    def interruptible_sleep(seconds)
      @sleep_mutex.synchronize do
        @sleep_cv.wait(@sleep_mutex, seconds) unless @stop
      end
      !stop?
    end

    def persist_start_intent(ct, source: 'autostart')
      lifecycle = ct.lifecycle

      daemon = Daemon.get
      request = daemon.with_lifecycle_admission do
        lifecycle.request_start(source:)
      end
      case request.action
      when :running
        state.set_started(ct)
        reboot.clear(ct)
        daemon.fulfil_upgrade_handoff(ct)
        :skip
      when :blocked, :failed, :superseded
        log(:warn, ct, request.warning || 'Unable to persist lifecycle start intent')
        :skip
      else
        daemon.fulfil_upgrade_handoff(ct)
        request
      end
    rescue CommandFailed => e
      log(:info, ct, "Lifecycle start intent deferred: #{e.message}")
      :skip
    end

    def track_pending(ct, request)
      return true unless request&.run_id

      key = pending_key(ct, request)
      accepted = @sleep_mutex.synchronize do
        next false if @stop || @shutdown

        @pending_intents[key] = [ct, request.run_id]
        true
      end
      return true if accepted

      ct.lifecycle.cancel_unlaunched(
        request.run_id,
        'autostart queue paused before launch'
      )
      false
    end

    def forget_pending(ct, request)
      return unless request&.run_id

      @sleep_mutex.synchronize do
        @pending_intents.delete(pending_key(ct, request))
      end
    end

    def cancel_pending(preserve_desired:, ct: nil)
      pending = @sleep_mutex.synchronize do
        selected = @pending_intents.select do |_key, entry|
          ct.nil? || entry[0] == ct
        end
        selected.each_key { |key| @pending_intents.delete(key) }
        selected.values
      end

      pending.each do |pending_ct, run_id|
        message = if preserve_desired
                    'autostart paused before launch'
                  else
                    'autostart queue cancelled'
                  end
        pending_ct.lifecycle.cancel_unlaunched(
          run_id,
          message,
          preserve_desired:,
          source: 'autostart-cancel'
        )
      end
    end

    def pending_key(ct, request)
      [ct.pool.name, ct.id, request.run_id.to_s, request.intent_id]
    end
  end
end
