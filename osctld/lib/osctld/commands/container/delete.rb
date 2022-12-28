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

      manipulate(ct) do
        progress('Stopping container')
        call_cmd!(
          Commands::Container::Stop,
          pool: ct.pool.name,
          id: ct.id,
          manipulation_lock: opts[:manipulation_lock],
          progress: opts[:progress],
        )

        if ct.send_log
          SendReceive.stopped_using_key(ct.pool, ct.send_log.opts.key_name)
        end

        progress('Disconnecting console')
        Console.remove(ct)

        progress('Removing shared mount directory')
        ct.clear_start_menu
        ct.mounts.shared_dir.remove

        progress('Moving dataset to trash')
        TrashBin.add_dataset(ct.pool, ct.dataset)

        progress('Removing LXC configuration and script hooks')
        Monitor::Master.demonitor(ct)
        syscmd("rm -rf #{ct.lxc_dir} #{ct.user_hook_script_dir}")

        if File.exist?(ct.log_path)
          File.rename(ct.log_path, "#{ct.log_path}.destroyed")
        end

        File.unlink(ct.config_path)

        progress('Unregistering container')
        DB::Containers.remove(ct)
        ct.pool.autostart_plan.clear_ct(ct)

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

      if !ct.user.standalone && !ct.user.has_containers?
        call_cmd!(
          Commands::User::Delete,
          pool: ct.user.pool.name,
          name: ct.user.name,
        )
      end

      progress('Reconfiguring LXC usernet')
      call_cmd(Commands::User::LxcUsernet)

      ok
    end
  end
end
