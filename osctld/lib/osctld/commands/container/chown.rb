module OsCtld
  class Commands::Container::Chown < Commands::Base
    handle :ct_chown

    include Utils::Log
    include Utils::System
    include Utils::Zfs

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      user = DB::Users.find(opts[:user], ct.pool)
      return error('user not found') unless user

      return error("already owned by #{user.name}") if ct.user == user

      return error('container has to be stopped first') if ct.state != :stopped
      Monitor::Master.demonitor(ct)

      old_user = ct.user

      user.inclusively do
        ct.exclusively do
          # Double check state while having exclusive lock
          next error('container has to be stopped first') if ct.state != :stopped

          # Ensure LXC home
          Dir.mkdir(ct.group.userdir(user), 0751) unless ct.group.setup_for?(user)

          # Move CT dir
          syscmd("mv #{ct.lxc_dir} #{ct.lxc_dir(user: user)}")
          File.chown(0, user.ugid, ct.lxc_dir(user: user))

          # Chown assets
          File.chown(0, user.ugid, ct.log_path) if File.exist?(ct.log_path)

          # Switch user, regenerate configs
          ct.chown(user)

          # Configure dataset
          zfs(:unmount, nil, ct.dataset)
          zfs(:set, "uidoffset=#{ct.uid_offset} gidoffset=#{ct.gid_offset}", ct.dataset)
          zfs(:mount, nil, ct.dataset)

          # Restart monitor
          Monitor::Master.monitor(ct)

          # Clear old LXC home if possible
          Dir.rmdir(ct.group.userdir(old_user)) unless ct.group.has_containers?(old_user)

          ok
        end
      end
    end
  end
end
