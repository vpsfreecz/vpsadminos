require 'libosctl'
require 'osctld/user_control/commands/base'

module OsCtld
  class UserControl::Commands::VethUp < UserControl::Commands::Base
    handle :veth_up

    include OsCtl::Lib::Utils::Log

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct
      return error('access denied') unless owns_ct?(ct)

      log(
        :info,
        ct,
        "veth interface coming up: ct=#{opts[:interface]}, host=#{opts[:veth]}"
      )
      ct.netifs[opts[:interface]].up(opts[:veth])

      Hook.run(
        ct,
        :veth_up,
        ct_veth: opts[:interface],
        host_veth: opts[:veth]
      )
      ok
    rescue HookFailed => e
      error(e.message)
    end
  end
end
