module OsCtld
  class Commands::Container::Create < Commands::Base
    handle :ct_create

    include Utils::Log
    include Utils::System
    include Utils::Zfs

    def execute
      pool = DB::Pools.get_or_default(opts[:pool])
      return error('pool not found') unless pool

      user = DB::Users.find(opts[:user], pool)
      return error('user not found') unless user

      if opts[:group]
        group = DB::Groups.find(opts[:group], pool)

      else
        group = DB::Groups.default(pool)
      end

      return error('group not found') unless group

      ct = Container.new(pool, opts[:id], user, group, load: false)

      user.inclusively do
        ct.exclusively do
          next error('container already exists') if DB::Containers.contains?(ct.id, pool)

          ### Rootfs
          zfs(:create, nil, ct.dataset)

          # Chown to 0:0, zfs will shift it to the offset
          File.chown(0, 0, ct.dir)
          File.chmod(0770, ct.dir)

          Dir.mkdir(ct.rootfs, 0750)
          File.chown(0, 0, ct.rootfs)

          ### LXC home
          Dir.mkdir(group.userdir(user), 0751) unless group.setup_for?(user)

          ## CT dir
          Dir.mkdir(ct.lxc_dir, 0750)
          File.chown(0, ct.user.ugid, ct.lxc_dir)

          # bashrc
          Template.render_to('ct/bashrc', {
            ct: ct,
            override: %w(
              attach cgroup console device execute info ls monitor stop top wait
            ),
            disable: %w(
              autostart checkpoint clone copy create destroy freeze snapshot
              start-ephemeral unfreeze unshare
            ),
          }, File.join(ct.lxc_dir, '.bashrc'))

          ### Rootfs
          syscmd("tar -xzf #{opts[:template]} -C #{ct.rootfs}")

          zfs(:unmount, nil, ct.dataset)
          zfs(:set, "uidoffset=#{ct.uid_offset} gidoffset=#{ct.gid_offset}", ct.dataset)
          zfs(:mount, nil, ct.dataset)

          ### Configuration
          distribution, version, *_ = File.basename(opts[:template]).split('-')

          ct.configure(
            user,
            group,
            distribution,
            version
          )

          ct.configure_lxc

          ### Log file
          File.open(ct.log_path, 'w').close
          File.chmod(0660, ct.log_path)
          File.chown(0, ct.user.ugid, ct.log_path)

          DB::Containers.add(ct)
          Monitor::Master.monitor(ct)

          ok
        end
      end
    end
  end
end
