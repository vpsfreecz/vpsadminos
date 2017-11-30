require 'erb'
require 'fileutils'

module OsCtld
  class Commands::User::Create < Commands::Base
    handle :user_create

    include Utils::Log
    include Utils::System
    include Utils::Zfs

    def execute
      u = User.new(opts[:name], load: false)

      zfs(:create, nil, u.dataset)
      zfs(:create, nil, u.ct_dataset)
      File.chown(0, opts[:ugid], u.homedir)
      File.chmod(0751, u.homedir)

      # Cache dir for LXC
      cache_dir = File.join(u.homedir, '.cache', 'lxc')
      FileUtils.mkdir_p(cache_dir)
      File.chmod(0775, cache_dir)
      File.chown(0, opts[:ugid], cache_dir)

      u.configure(opts[:ugid], opts[:offset], opts[:size])

      # bashrc
      bashrc = File.join(u.homedir, '.bashrc')

      @user = u
      @override = %w(attach cgroup console device execute info ls monitor start stop
        top wait)
      @disable = %w(autostart checkpoint clone copy create destroy freeze snapshot
        start-ephemeral unfreeze unshare)

      File.open(bashrc, 'w') do |f|
        f.write(ERB.new(File.new(OsCtld.tpl('user_bashrc')).read, 0, '-').result(binding))
      end

      u.register

      UserList.sync do
        UserList.add(u)
        call_cmd(Commands::User::SubUGIds)
      end

      ok
    end
  end
end
