module OsCtld
  class UserControl::Commands::VethUp < UserControl::Commands::Base
    handle :veth_up

    include Utils::Log

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct
      return error('access denied') unless owns_ct?(ct)

      log(
        :info,
        ct,
        "veth interface coming up: ct=#{opts[:interface]}, host=#{opts[:veth]}"
      )
      ct.netif_by(opts[:interface]).up(opts[:veth])
      ok
    end
  end
end
