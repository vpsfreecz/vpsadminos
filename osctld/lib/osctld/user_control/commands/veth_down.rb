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
      return error('access denied') unless owns_ct?(ct)

      run = lifecycle_run(ct, allow_active: true)
      return error('managed lifecycle run not found') unless run

      interface = run.dig('resources', 'network_interfaces', opts[:interface])
      if interface.nil? && run.dig('resources', 'cgroup_root') != ct.base_cgroup_path
        return error('network interface does not belong to lifecycle run')
      end
      if interface && interface['veth'] != opts[:veth]
        return error('network interface does not belong to lifecycle run')
      end

      log(
        :info,
        ct,
        "veth interface coming down: ct=#{opts[:interface]}, host=#{opts[:veth]}"
      )
      netif = ct.netifs[opts[:interface]]
      return error('network interface not found') unless netif

      netif.down(opts[:veth])

      Hook.run(
        ct,
        :veth_down,
        ct_veth: opts[:interface],
        host_veth: opts[:veth]
      )
      ok
    rescue HookFailed => e
      error(e.message)
    end
  end
end
