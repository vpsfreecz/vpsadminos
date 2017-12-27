module OsCtld
  # Remove group directory from userdir
  class Commands::Group::UserDel < Commands::Base
    handle :group_user_del

    def execute
      grp = GroupList.find(opts[:name])
      return error('group not found') unless grp

      u = UserList.find(opts[:user])
      return error('user not found') unless u

      dir = u.lxc_home(grp)
      bashrc = File.join(dir, '.bashrc')

      File.unlink(bashrc) if File.exist?(bashrc)
      Dir.rmdir(dir)

      ok
    end
  end
end
