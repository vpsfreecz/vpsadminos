require 'osctld/commands/logged'
require 'osctld/container/forced_stop'

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
      manipulate(ct) do
        progress('Stopping container')

        # Remove the container from autostart queue
        ct.pool.autostart_plan.stop_ct(ct)

        mode =
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

        if %i[freezing frozen].include?(ct.state)
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

        # Give the container more memory, so that the shutdown does not hang
        # in low memory situations.
        ct.cgparams.temporarily_expand_memory if ct.running?

        run_conf = ct.get_run_conf
        forced_stop = Container::ForcedStop.new(ct, run_conf:)

        promise = ct.get_exit_promise

        begin
          DistConfig.run(
            ct.get_run_conf,
            :stop,
            mode:,
            forced_stop:,
            message: opts[:message],
            timeout: opts[:timeout] || Container::DEFAULT_STOP_TIMEOUT
          )
        rescue ContainerControl::UserRunnerError => e
          error!(e.message) if mode == :shutdown

          ct.log(:warn, 'Unable to stop, killing by force')
          progress('Unable to stop, killing by force')

          unless force_kill(ct, forced_stop:)
            ct.log(:warn, 'Unable to kill or cleanup')
            error!('Unable to kill or cleanup')
          end
        rescue ContainerControl::Error => e
          error!(e.message)
        end

        if promise
          wait_opts = forced_stop.started? ? { timeout: forced_stop.time_left } : {}
          if promise.wait(**wait_opts)
            ct.log(:debug, 'Exit promise fulfilled')
          else
            ct.log(:warn, 'Timeout while waiting for exit promise')
            if forced_stop.started?
              forced_stop.taint
            else
              ct.state = :error
            end
            error!('Timeout while waiting for container exit')
          end
        end

        remove_accounting_cgroups(ct)

        if ct.ephemeral? && !indirect?
          call_cmd!(
            Commands::Container::Delete,
            pool: ct.pool.name,
            id: ct.id,
            force: true
          )
        end

        ok
      end
    end

    protected

    # @return [Boolean]
    def force_kill(ct, forced_stop: Container::ForcedStop.new(ct))
      ContainerControl::Commands::Stop.run!(ct, :kill, forced_stop:)
      true
    rescue ContainerControl::Error => e
      ct.log(:warn, "Forced stop failed: #{e.message}")
      false
    end
  end
end
