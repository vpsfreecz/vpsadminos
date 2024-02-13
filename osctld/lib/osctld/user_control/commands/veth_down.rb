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

      log(
        :info,
        ct,
        "veth interface coming down: ct=#{opts[:interface]}, host=#{opts[:veth]}"
      )
      ct.netifs[opts[:interface]].down(opts[:veth])

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
