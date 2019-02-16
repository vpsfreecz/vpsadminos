require 'osctld/commands/base'

module OsCtld
  class Commands::Container::RecoverState < Commands::Base
    handle :ct_recover_state

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      manipulate(ct) do
        orig_state = ct.state
        current_state = ct.current_state

        if orig_state == current_state
          next(ok)

        elsif current_state == :stopped
          # Put all network interfaces down
          ct.netifs.take_down

          # Unload AppArmor profile and destroy namespace
          ct.apparmor.destroy_namespace
          ct.apparmor.unload_profile

          ct.stopped

          # User-defined hook
          Container::Hook.run(ct, :post_stop)
        end

        ok
      end
    end
  end
end
