require 'osctld/commands/base'

module OsCtld
  class Commands::Container::RecoverState < Commands::Base
    handle :ct_recover_state

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      manipulate(ct) do
        recover_state(ct)
      end
    end

    protected
    def recover_state(ct)
      orig_state = ct.state
      current_state = ct.current_state

      if orig_state == current_state
        return ok

      elsif current_state == :stopped
        # Put all network interfaces down
        ct.netifs.take_down

        # Unload AppArmor profile and destroy namespace
        ct.apparmor.destroy_namespace
        ct.apparmor.unload_profile

        ct.stopped

        # User-defined hook
        Container::Hook.run(ct, :post_stop)

        # Announce the change first as :aborting, that will cause a waiting
        # osctl ct start to give it up
        Eventd.report(:state, pool: ct.pool.name, id: ct.id, state: :aborting)
        Eventd.report(:state, pool: ct.pool.name, id: ct.id, state: :stopped)

      else
        # Announce the change
        Eventd.report(:state, pool: ct.pool.name, id: ct.id, state: change[:state])
      end

      ok
    end
  end
end
