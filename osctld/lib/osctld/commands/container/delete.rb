require 'osctld/commands/logged'

module OsCtld
  class Commands::Container::Delete < Commands::Logged
    handle :ct_delete

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::SwitchUser

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!("container not found")
    end

    def execute(ct)
      if !opts[:force]
        ct.exclusively do
          error!('the container is running') if ct.running?
        end
      end

      # Remove monitor _before_ acquiring exclusive lock, because monitor
      # uses inclusive lock, which would result in a deadlock
      Monitor::Master.demonitor(ct)

      ct.exclusively do
        stop = call_cmd(Commands::Container::Stop, id: ct.id)

        progress('Stopping container')
        return error('unable to stop the container') unless stop[:status]

        progress('Disconnecting console')
        Console.remove(ct)

        progress('Removing devices')
        syscmd("rm -rf #{ct.devices_dir}") if Dir.exist?(ct.devices_dir)

        progress('Removing shared mount directory')
        ct.mounts.shared_dir.remove

        progress('Destroying dataset')
        zfs(:destroy, '-r', ct.dataset)

        progress('Removing LXC configuration and script hooks')
        syscmd("rm -rf #{ct.lxc_dir} #{ct.user_hook_script_dir}")
        File.unlink(ct.log_path) if File.exist?(ct.log_path)
        File.unlink(ct.config_path)

        progress('Unregistering container')
        DB::Containers.remove(ct)

        progress('Removing cgroups')
        begin
          if ct.group.has_containers?(ct.user)
            CGroup.rmpath_all(ct.base_cgroup_path)

          else
            CGroup.rmpath_all(ct.group.full_cgroup_path(ct.user))
          end
        rescue SystemCallError
          # If some of the cgroups are busy, just leave them be
        end

        progress('Removing AppArmor profile')
        ct.apparmor.destroy_namespace
        ct.apparmor.destroy_profile

        bashrc = File.join(ct.lxc_dir, '.bashrc')
        File.unlink(bashrc) if File.exist?(bashrc)

        unless ct.group.has_containers?(ct.user)
          Dir.rmdir(ct.group.userdir(ct.user))
        end
      end

      progress('Reconfiguring LXC usernet')
      call_cmd(Commands::User::LxcUsernet)

      ok
    end
  end
end
