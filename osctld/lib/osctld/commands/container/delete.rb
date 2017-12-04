module OsCtld
  class Commands::Container::Delete < Commands::Base
    handle :ct_delete

    include Utils::Log
    include Utils::System
    include Utils::Zfs
    include Utils::SwitchUser

    def execute
      ct = ContainerList.find(opts[:id])
      return error("container not found") unless ct

      ct.exclusively do
        stop = ct_control(ct.user, :ct_stop, id: ct.id)
        return error('unable to stop the container') unless stop[:status]

        zfs(:destroy, nil, ct.dataset)

        ContainerList.remove(ct)
      end

      call_cmd(Commands::User::LxcUsernet)

      ok
    end
  end
end
