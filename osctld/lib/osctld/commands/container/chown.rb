require 'osctld/commands/logged'
require 'fileutils'

module OsCtld
  class Commands::Container::Chown < Commands::Logged
    handle :ct_chown

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      new_user = DB::Users.find(opts[:user], ct.pool)

      if new_user.nil?
        error!('user not found')
      elsif ct.user == new_user
        error!("already owned by #{new_user.name}")
      elsif ct.state != :stopped
        error!('container has to be stopped first')
      end

      Monitor::Master.demonitor(ct)

      old_user = ct.user

      manipulate([ct, new_user, old_user]) do
        # Double check state
        error!('container has to be stopped first') if ct.state != :stopped

        progress('Moving LXC configuration')

        # Ensure LXC home
        unless ct.group.setup_for?(new_user)
          dir = ct.group.userdir(new_user)

          FileUtils.mkdir_p(dir, mode: 0o751)
          File.chown(0, new_user.ugid, dir)
        end

        # Move CT dir
        syscmd("mv #{ct.lxc_dir} #{ct.lxc_dir(user: new_user)}")
        File.chown(0, new_user.ugid, ct.lxc_dir(user: new_user))

        # Chown assets
        File.chown(0, new_user.ugid, ct.log_path) if File.exist?(ct.log_path)

        # Switch user, regenerate configs
        ct.chown(new_user)

        # Configure datasets
        if new_user.uid_map != old_user.uid_map \
           || new_user.gid_map != old_user.gid_map
          datasets = ct.datasets

          datasets.reverse_each do |ds|
            progress("Unmounting dataset #{ds.relative_name}")
            zfs(:unmount, nil, ds, valid_rcs: [1])
          end

          datasets.each do |ds|
            progress("Setting UID/GID mapping of #{ds.relative_name}")
            zfs(
              :set,
              "uidmap=\"#{ct.uid_map.map(&:to_s).join(',')}\" " +
              "gidmap=\"#{ct.gid_map.map(&:to_s).join(',')}\"",
              ds
            )

            progress("Remounting dataset #{ds.relative_name}")
            zfs(:mount, nil, ds)
          end
        end

        # Restart monitor
        Monitor::Master.monitor(ct)

        # Clear old LXC home if possible
        unless ct.group.has_containers?(old_user)
          progress('Cleaning up original LXC home')
          Dir.rmdir(ct.group.userdir(old_user))
        end
      end

      call_cmd(Commands::User::LxcUsernet)
      ok
    end
  end
end
