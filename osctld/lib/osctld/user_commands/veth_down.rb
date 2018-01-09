module OsCtld
  class UserCommands::VethDown < UserCommands::Base
    handle :veth_down

    include Utils::Log

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct
      return error('access denied') unless owns_ct?(ct)

      log(
        :info,
        ct,
        "veth interface coming down: ct=#{opts[:interface]}, host=#{opts[:veth]}"
      )
      ct.netif_by(opts[:interface]).down(opts[:veth])
      ok
    end
  end
end
