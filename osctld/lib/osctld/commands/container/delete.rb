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

      # Remove monitor _before_ acquiring exclusive lock, because monitor
      # uses inclusive lock, which would result in a deadlock
      Monitor::Master.demonitor(ct)

      ct.exclusively do
        stop = call_cmd(Commands::Container::Stop, id: ct.id)
        return error('unable to stop the container') unless stop[:status]

        Console.remove(ct)

        zfs(:destroy, nil, ct.dataset)
        syscmd("rm -rf #{ct.lxc_dir}")
        File.unlink(ct.config_path)

        ContainerList.remove(ct)
      end

      call_cmd(Commands::User::LxcUsernet)

      ok
    end
  end
end
