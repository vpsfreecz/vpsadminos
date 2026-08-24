require 'osctld/commands/logged'

module OsCtld
  class Commands::Container::Stop < Commands::Logged
    handle :ct_stop

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::Container
    include Utils::SwitchUser

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      daemon = Daemon.get
      intent_id = opts[:lifecycle_intent_id]
      queue_stopped = false

      loop do
        request = manipulate(ct, lifecycle: true) do
          daemon.with_lifecycle_admission(
            internal: client_handler.nil?,
            continuation: indirect? && !intent_id.nil?,
            recovery: client_handler.nil? && opts[:lifecycle_recovery] == true
          ) do
            unless queue_stopped
              ct.pool.autostart_plan.stop_ct(ct)
              queue_stopped = true
            end
            ct.lifecycle.request_stop(
              source: opts[:lifecycle_source] || 'external',
              expected_intent_id: intent_id
            )
          end
        end
        intent_id ||= request.intent_id

        case request.action
        when :stopped
          return ok(lifecycle_state: 'stopped')
        when :superseded
          return error('container stop intent was superseded')
        when :wait
          progress('Waiting for the active lifecycle effect')
          changed = ct.lifecycle.wait_for_change(request.revision)
          return error('osctld is shutting down') if changed == :shutdown

          next
        when :stop
          progress('Stopping container')
        else
          return error("unsupported lifecycle action #{request.action.inspect}")
        end

        effect_id = ct.lifecycle.claim_effect(
          request.run_id,
          :stop
        )

        unless effect_id
          changed = ct.lifecycle.wait_for_change(request.revision)
          return error('osctld is shutting down') if changed == :shutdown

          next
        end

        stop_in_background(ct, request, effect_id)

        progress('Waiting for exact container generation cleanup')
        phase = ct.lifecycle.wait_for_stop(request.run_id)

        if phase == :shutdown
          return error('osctld is shutting down')
        elsif phase == :quarantined
          return ok(
            lifecycle_state: 'quarantined',
            run_id: request.run_id.to_s,
            warning: 'container generation remains as an unkillable residual'
          )
        elsif %i[failed cleanup_failed].include?(phase)
          return error('container lifecycle failed while stopping')
        elsif phase == :stop_failed
          run = ct.lifecycle.run(request.run_id)
          return error((run && run['stop_error']) || 'container stop failed')
        else
          return ok(lifecycle_state: 'stopped', run_id: request.run_id.to_s)
        end
      end
    end

    protected

    def stop_in_background(ct, request, effect_id)
      thread = Thread.new do
        acquired = Container::LifecycleExecutor.acquire(ct.pool, :stop, effect_id)
        next unless acquired

        ct.lifecycle.set_effect_worker(request.run_id, effect_id, Process.pid)
        issue_stop(
          ct,
          request.run_id,
          effect_id,
          report_progress: false
        )
        ct.lifecycle.finish_effect(request.run_id, effect_id)
        finalize_effect_id = ct.lifecycle.claim_finalization(request.run_id)
        if finalize_effect_id
          run_conf = [ct.run_conf, ct.get_past_run_conf].compact.detect do |conf|
            conf.run_id == request.run_id
          end
          if run_conf
            Container::LifecycleFinalizer.spawn(
              ct,
              run_conf,
              finalize_effect_id
            )
          else
            ct.lifecycle.fail_cleanup(
              request.run_id,
              finalize_effect_id,
              'exact run configuration is missing'
            )
          end
        end
      rescue StandardError => e
        ct.lifecycle.fail_stop(request.run_id, effect_id, e.message)
        log(:warn, ct, "Background stop failed: #{e.message} (#{e.class})")
      ensure
        ct.lifecycle.effect_worker_exited(request.run_id, effect_id)
        Container::LifecycleExecutor.release(ct.pool, :stop, effect_id)
      end
      ThreadReaper.add(thread, nil, group: :durable_lifecycle)
    end

    def issue_stop(ct, run_id, effect_id, report_progress: true)
      ensure_effect!(ct, run_id, effect_id)
      mode = stop_mode

      if %i[freezing frozen].include?(ct.runtime_state)
        if mode == :stop
          mode = :kill
        elsif mode == :shutdown
          error!('The container is frozen, unable to shutdown')
        end
      end

      begin
        Hook.run(ct, :pre_stop)
      rescue HookFailed => e
        error!(e.message)
      end
      ensure_effect!(ct, run_id, effect_id)

      ct.cgparams.temporarily_expand_memory if ct.running?
      ensure_effect!(ct, run_id, effect_id)
      run_conf = ct.run_conf || ct.get_past_run_conf
      error!('active run configuration not found') unless run_conf
      error!('active run changed') unless run_conf.run_id == run_id

      begin
        DistConfig.run(
          run_conf,
          :stop,
          mode:,
          message: opts[:message],
          timeout: opts[:timeout] || Container::DEFAULT_STOP_TIMEOUT
        )
      rescue ContainerControl::UserRunnerError
        ct.log(:warn, 'Unable to stop, killing by force')
        progress('Unable to stop, killing by force') if report_progress

        unless force_kill(
          ct,
          run_id,
          effect_id,
          report_progress:
        )
          ct.log(:warn, 'Unable to kill or establish stopped state')
          error!('Unable to kill or establish stopped state')
        end
      rescue ContainerControl::Error => e
        error!(e.message)
      end

      ensure_effect!(ct, run_id, effect_id)
    end

    def stop_mode
      case opts.fetch(:method, 'shutdown_or_kill')
      when 'shutdown_or_kill'
        :stop
      when 'shutdown_or_fail'
        :shutdown
      when 'kill'
        :kill
      else
        error!("unknown stop method '#{opts[:method]}'")
      end
    end

    # @return [Boolean]
    def force_kill(ct, run_id, effect_id, report_progress: true)
      recovery = Container::Recovery.new(ct)

      # Freeze all processes before the kill
      frozen = false
      begin
        recovery.freeze_generation(run_id)
        frozen = true
        ensure_effect!(ct, run_id, effect_id)

        # Send SIGKILL to all processes
        progress('Killing container processes') if report_progress
        recovery.kill_generation(run_id)
        ensure_effect!(ct, run_id, effect_id)
      ensure
        # A live stop worker retains effect ownership, so recovery cannot
        # supersede it. If ownership was nevertheless transferred, the exact
        # recovery worker owns the generation and its freeze/thaw sequence.
        if frozen && ct.lifecycle.effect_current?(run_id, effect_id)
          recovery.thaw_generation(run_id)
        end
      end
      ensure_effect!(ct, run_id, effect_id)

      progress('Recovering container state') if report_progress
      recovery.recover_state(run_id:)
      ensure_effect!(ct, run_id, effect_id)
      true
    end

    def ensure_effect!(ct, run_id, effect_id)
      return true if ct.lifecycle.effect_current?(run_id, effect_id)

      raise CommandFailed, 'container stop was superseded by recovery'
    end
  end
end
