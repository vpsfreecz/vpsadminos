require 'fileutils'

module OsCtld
  class Commands::User::Create < Commands::Base
    handle :user_create

    include Utils::Log
    include Utils::System
    include Utils::Zfs

    def execute
      u = User.new(opts[:name], load: false)
      return error('user already exists') if UserList.contains?(u.name)

      u.exclusively do
        zfs(:create, nil, u.dataset)
        zfs(:create, nil, u.ct_dataset)

        File.chown(0, opts[:ugid], u.userdir)
        File.chmod(0751, u.userdir)

        Dir.mkdir(u.homedir) unless Dir.exist?(u.homedir)
        File.chown(opts[:ugid], opts[:ugid], u.homedir)
        File.chmod(0751, u.homedir)

        # Cache dir for LXC
        cache_dir = File.join(u.homedir, '.cache', 'lxc')
        FileUtils.mkdir_p(cache_dir)
        File.chmod(0775, cache_dir)
        File.chown(0, opts[:ugid], cache_dir)

        u.configure(opts[:ugid], opts[:offset], opts[:size])

        # bashrc
        Template.render_to('user/bashrc', {
          user: u,
          override: %w(
            attach cgroup console device execute info ls monitor start stop
            top wait
          ),
          disable: %w(
            autostart checkpoint clone copy create destroy freeze snapshot
            start-ephemeral unfreeze unshare
          ),
        }, File.join(u.homedir, '.bashrc'))

        u.register

        UserList.sync do
          UserList.add(u)
          call_cmd(Commands::User::SubUGIds)
        end

        UserControl::Supervisor.start_server(u)
      end

      ok
    end
  end
end
