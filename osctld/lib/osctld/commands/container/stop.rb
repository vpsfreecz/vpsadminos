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
      manipulate(ct) do
        progress('Stopping container')

        # Remove the container from autostart queue
        ct.pool.autostart_plan.stop_ct(ct)

        mode =
          case (opts[:method] || 'shutdown_or_kill')
          when 'shutdown_or_kill'
            :stop
          when 'shutdown_or_fail'
            :shutdown
          when 'kill'
            :kill
          else
            error!("unknown stop method '#{opts[:method]}'")
          end

        if %i(freezing frozen).include?(ct.state)
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

        # Disable ksoftlimd
        if CGroup.v1?
          begin
            CGroup.set_param(
              File.join(
                CGroup.abs_cgroup_path('memory', ct.base_cgroup_path),
                'memory.ksoftlimd_control'
              ),
              ['0'],
            )
          rescue CGroupFileNotFound
            # This can happen when the container is already stopped
          end
        end

        begin
          DistConfig.run(
            ct.get_run_conf,
            :stop,
            mode: mode,
            timeout: opts[:timeout] || 60,
          )
        rescue ContainerControl::UserRunnerError
          ct.log(:warn, 'Unable to stop, killing by force')
          progress('Unable to stop, killing by force')

          unless force_kill(ct)
            ct.log(:warn, 'Unable to kill or cleanup')
            error!('Unable to kill or cleanup')
          end
        rescue ContainerControl::Error => e
          error!(e.message)
        end

        remove_accounting_cgroups(ct)

        if ct.ephemeral? && !indirect?
          call_cmd!(
            Commands::Container::Delete,
            pool: ct.pool.name,
            id: ct.id,
            force: true,
          )
        end

        ok
      end
    end

    protected
    # @return [Boolean]
    def force_kill(ct)
      recovery = Container::Recovery.new(ct)

      # Freeze all processes before the kill
      CGroup.freeze_tree(ct.cgroup_path)

      # Send SIGKILL to all processes
      progress('Killing container processes')
      recovery.kill_all

      # Thaw all processes
      CGroup.thaw_tree(ct.cgroup_path)

      # Give the system some time to kill the processes
      sleep(10)

      progress('Recovering container state')
      recovery.recover_state

      progress('Cleaning up')
      recovery.cleanup_or_taint
    end
  end
end
