module OsCtld
  class Commands::Container::Delete < Commands::Base
    handle :ct_delete

    include Utils::Log
    include Utils::System
    include Utils::Zfs
    include Utils::SwitchUser

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error("container not found") unless ct

      # Remove monitor _before_ acquiring exclusive lock, because monitor
      # uses inclusive lock, which would result in a deadlock
      Monitor::Master.demonitor(ct)

      ct.exclusively do
        stop = call_cmd(Commands::Container::Stop, id: ct.id)

        progress('Stopping container')
        return error('unable to stop the container') unless stop[:status]

        progress('Disconnecting console')
        Console.remove(ct)

        progress('Destroying dataset')
        zfs(:destroy, nil, ct.dataset)

        progress('Removing LXC configuration')
        syscmd("rm -rf #{ct.lxc_dir}")
        File.unlink(ct.log_path) if File.exist?(ct.log_path)
        File.unlink(ct.config_path)

        progress('Unregistering container')
        DB::Containers.remove(ct)

        bashrc = File.join(ct.lxc_dir, '.bashrc')
        File.unlink(bashrc) if File.exist?(bashrc)
        Dir.rmdir(ct.group.userdir(ct.user)) unless ct.group.has_containers?(ct.user)
      end

      progress('Reconfiguring LXC usernet')
      call_cmd(Commands::User::LxcUsernet)

      ok
    end
  end
end
