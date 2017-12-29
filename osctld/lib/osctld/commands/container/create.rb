module OsCtld
  class Commands::Container::Create < Commands::Base
    handle :ct_create

    include Utils::Log
    include Utils::System
    include Utils::Zfs

    def execute
      user = UserList.find(opts[:user])
      return error('user not found') unless user

      if opts[:group]
        group = GroupList.find(opts[:group])

      else
        group = GroupList.default
      end

      return error('group not found') unless group

      ct = Container.new(opts[:id], user, group, load: false)

      user.inclusively do
        ct.exclusively do
          next error('container already exists') if ContainerList.contains?(ct.id)

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

          Template.render_to('ct/config', {
            distribution: distribution,
            ct: ct,
            hook_start_host: OsCtld::hook_run('ct-start'),
          }, ct.lxc_config_path)

          ct.configure_network

          ContainerList.add(ct)
          Monitor::Master.monitor(ct)

          ok
        end
      end
    end
  end
end
