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
      if opts[:reboot]
        begin
          loop do
            request = manipulate(ct, lifecycle: true) do
              admission = ct.lifecycle.request_control_reboot
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
        loop do
          request = manipulate(ct, lifecycle: true) do
            ct.lifecycle.request_restart
          end
          progress(request.warning) if request.warning

          case request.action
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
          lifecycle_intent_id: intent_id
        )
        return stop_ret unless stop_ret[:status]

        call_cmd!(
          Commands::Container::Start,
          pool: ct.pool.name,
          id: ct.id,
          force: true,
          wait: opts[:wait],
          lifecycle_source: 'restart',
          lifecycle_intent_id: intent_id
        )
      end
    end
  end
end
