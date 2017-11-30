module OsCtld
  class Commands::User::List < Commands::Base
    handle :user_list

    def execute
      ret = UserList.get.map do |u|
        {
          name: u.name,
          username: u.username,
          groupname: u.groupname,
          ugid: u.ugid,
          ugid_offset: u.offset,
          ugid_size: u.size,
          dataset: u.dataset,
          homedir: u.homedir,
          registered: u.registered?,
        }
      end

      ok(ret)
    end
  end
end
