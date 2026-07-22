require 'libosctl'
require 'osctld/user_control/commands/base'

module OsCtld
  class UserControl::Commands::VethDown < UserControl::Commands::Base
    handle :veth_down

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      ret = authenticate_lifecycle_callback(ct)
      return ret if ret

      netif = ct.netifs[opts[:interface]]
      return error('network interface not found') unless netif.is_a?(NetInterface::Veth)

      host_identity = netif.validate_down_callback(opts[:veth])
      return error('host veth identity is not registered') unless host_identity

      host_veth = host_identity.fetch(0)
      with_claimed_lifecycle_event(
        ct,
        "veth_down:#{netif.name}",
        after: "veth_up:#{netif.name}"
      ) do
        log(
          :info,
          ct,
          "veth interface coming down: ct=#{netif.name}, host=#{host_veth}"
        )

        netif.down(host_veth)

        Hook.run(
          ct,
          :veth_down,
          ct_veth: netif.name,
          host_veth:
        )
        ok
      end
    rescue HookFailed, NetInterface::Veth::InvalidHostLink => e
      error(e.message)
    end
  end
end
