module OsCtld
  class Commands::Container::IpList < Commands::Base
    handle :ct_ip_list

    include Utils::Log
    include Utils::System
    include Utils::SwitchUser

    def execute
      ct = ContainerList.find(opts[:id])
      return error('container not found') unless ct

      ok(4 => ct.ips(4), 6 => ct.ips(6))
    end
  end
end
