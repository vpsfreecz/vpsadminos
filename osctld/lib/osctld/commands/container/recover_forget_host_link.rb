require 'osctld/commands/base'

module OsCtld
  # This command is available only on the privileged osctld command socket.
  class Commands::Container::RecoverForgetHostLink < Commands::Base
    handle :ct_recover_forget_host_link

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      manipulate(ct) do
        Container::Recovery.new(ct).forget_host_link(opts[:netif])
        ok
      end
    rescue Container::Recovery::InvalidNetifIdentity, NetInterface::HostLinkClaimError => e
      error(e.message)
    end
  end
end
