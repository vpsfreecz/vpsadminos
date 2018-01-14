module OsCtld
  class Commands::Container::Create < Commands::Logged
    handle :ct_create

    include Utils::Log
    include Utils::System
    include Utils::Zfs

    def find
      pool = DB::Pools.get_or_default(opts[:pool])
      error!('pool not found') unless pool

      user = DB::Users.find(opts[:user], pool)
      error!('user not found') unless user

      if opts[:group]
        group = DB::Groups.find(opts[:group], pool)

      else
        group = DB::Groups.default(pool)
      end

      error!('group not found') unless group

      rx = /^[a-z0-9_-]{1,100}$/i
      error!("invalid id, allowed format: #{rx.source}") if rx !~ opts[:id]

      Container.new(pool, opts[:id], user, group, load: false)
    end

    def execute(ct)
      pool = ct.pool
      user = ct.user
      group = ct.group

      user.inclusively do
        ct.exclusively do
          next error('container already exists') if DB::Containers.contains?(ct.id, pool)

          ### Rootfs
          progress('Creating dataset')
          zfs(:create, nil, ct.dataset)

          # Chown to 0:0, zfs will shift it to the offset
          File.chown(0, 0, ct.dir)
          File.chmod(0770, ct.dir)

          Dir.mkdir(ct.rootfs, 0750)
          File.chown(0, 0, ct.rootfs)

          ### LXC home
          progress('Configuring LXC home')
          Dir.mkdir(group.userdir(user), 0751) unless group.setup_for?(user)

          ## CT dir
          Dir.mkdir(ct.lxc_dir, 0750)
          File.chown(0, ct.user.ugid, ct.lxc_dir)

          # bashrc
          ct.configure_bashrc

          ### Rootfs
          progress('Extracting template')
          syscmd("tar -xzf #{opts[:template]} -C #{ct.rootfs}")

          progress('Unmounting dataset')
          zfs(:unmount, nil, ct.dataset)

          progress('Configuring UID/GID offsets')
          zfs(:set, "uidoffset=#{ct.uid_offset} gidoffset=#{ct.gid_offset}", ct.dataset)

          progress('Remounting dataset')
          zfs(:mount, nil, ct.dataset)

          ### Configuration
          progress('Generating LXC configuration')
          distribution, version, *_ = File.basename(opts[:template]).split('-')

          ct.configure(
            user,
            group,
            distribution,
            version
          )

          ct.configure_lxc

          ### Log file
          progress('Preparing log file')
          File.open(ct.log_path, 'w').close
          File.chmod(0660, ct.log_path)
          File.chown(0, ct.user.ugid, ct.log_path)

          progress('Registering container')
          DB::Containers.add(ct)
          Monitor::Master.monitor(ct)

          ok
        end
      end
    end
  end
end
