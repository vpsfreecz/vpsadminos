require 'osctld/commands/logged'

module OsCtld
  class Commands::Container::Restart < Commands::Logged
    handle :ct_restart

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::SwitchUser

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      daemon = Daemon.get
      admission_opts = {
        internal: client_handler.nil?,
        continuation: false,
        recovery: client_handler.nil? && opts[:lifecycle_recovery] == true
      }
      if opts[:reboot]
        begin
          loop do
            request = manipulate(ct, lifecycle: true) do
              admission = daemon.with_lifecycle_admission(**admission_opts) do
                ct.lifecycle.request_control_reboot
              end
              if admission.action == :ready
                begin
                  ContainerControl::Commands::Reboot.run!(ct)
                  :rebooted
                rescue ContainerControl::Error => e
                  ct.lifecycle.record_control_reboot_error(
                    admission.run_id,
                    admission.effect_id,
                    e.message
                  )
                  raise
                end
              else
                admission
              end
            end

            return ok if request == :rebooted

            progress(request.warning) if request.warning
            case request.action
            when :wait
              progress('Waiting for container lifecycle to settle')
              changed = ct.lifecycle.wait_for_change(request.revision)
              error!('osctld is shutting down') if changed == :shutdown
            when :blocked
              error!(request.warning || 'container reboot is blocked')
            else
              error!("invalid reboot admission #{request.action.inspect}")
            end
          end
        rescue ContainerControl::Error => e
          error!(e.message)
        end

      else
        request = nil
        expected_intent_id = opts[:lifecycle_expected_intent_id]
        loop do
          request = manipulate(ct, lifecycle: true) do
            daemon.with_lifecycle_admission(**admission_opts) do
              ct.lifecycle.request_restart(
                source: opts[:lifecycle_source] || 'external',
                expected_intent_id:
              )
            end
          end
          progress(request.warning) if request.warning

          case request.action
          when :superseded
            return ok(
              lifecycle_state: ct.lifecycle.desired_state.to_s,
              superseded: true
            )
          when :wait
            progress('Waiting for container cgroup policy update')
            changed = ct.lifecycle.wait_for_change(request.revision)
            error!('osctld is shutting down') if changed == :shutdown
          when :blocked
            error!(request.warning || 'container lifecycle restart is blocked')
          else
            break
          end
        end
        intent_id = request.effect_id

        stop_ret = call_cmd!(
          Commands::Container::Stop,
          pool: ct.pool.name,
          id: ct.id,
          timeout: opts[:stop_timeout],
          method: opts[:stop_method],
          message: opts[:message],
          lifecycle_source: 'restart',
          lifecycle_intent_id: intent_id,
          lifecycle_recovery: opts[:lifecycle_recovery]
        )
        return stop_ret unless stop_ret[:status]

        call_cmd!(
          Commands::Container::Start,
          pool: ct.pool.name,
          id: ct.id,
          force: true,
          wait: opts[:wait],
          lifecycle_source: 'restart',
          lifecycle_intent_id: intent_id,
          lifecycle_recovery: opts[:lifecycle_recovery]
        )
      end
    end
  end
end
