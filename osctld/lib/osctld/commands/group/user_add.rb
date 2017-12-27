module OsCtld
  # Setup group directory in userdir
  class Commands::Group::UserAdd < Commands::Base
    handle :group_user_add

    def execute
      grp = GroupList.find(opts[:name])
      return error('group not found') unless grp

      u = UserList.find(opts[:user])
      return error('user not found') unless u

      dir = u.lxc_home(grp)

      Dir.mkdir(dir, 0751)

      # bashrc
      Template.render_to('user/bashrc', {
        user: u,
        group: grp,
        override: %w(
          attach cgroup console device execute info ls monitor stop top wait
        ),
        disable: %w(
          autostart checkpoint clone copy create destroy freeze snapshot
          start-ephemeral unfreeze unshare
        ),
      }, File.join(dir, '.bashrc'))

      ok
    end
  end
end
