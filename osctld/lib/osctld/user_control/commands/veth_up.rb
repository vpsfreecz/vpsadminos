require 'libosctl'
require 'osctld/user_control/commands/base'

module OsCtld
  class UserControl::Commands::VethUp < UserControl::Commands::Base
    handle :veth_up

    include OsCtl::Lib::Utils::Log

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      ret = authenticate_lifecycle_callback(ct)
      return ret if ret

      netif = ct.netifs[opts[:interface]]
      return error('network interface not found') unless netif.is_a?(NetInterface::Veth)

      host_veth, = netif.validate_up_callback(opts[:veth])
      with_claimed_lifecycle_event(
        ct,
        "veth_up:#{netif.name}",
        after: :pre_start
      ) do
        log(
          :info,
          ct,
          "veth interface coming up: ct=#{netif.name}, host=#{host_veth}"
        )

        netif.up(host_veth)

        Hook.run(
          ct,
          :veth_up,
          ct_veth: netif.name,
          host_veth:,
          enable: netif.enable
        )
        ok
      end
    rescue HookFailed, NetInterface::Veth::InvalidHostLink => e
      error(e.message)
    end
  end
end
