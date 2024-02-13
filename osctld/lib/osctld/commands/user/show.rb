require 'osctld/commands/base'

module OsCtld
  class Commands::User::Show < Commands::Base
    handle :user_show

    def execute
      u = DB::Users.find(opts[:name], opts[:pool])
      return error('user not found') unless u

      ok({
        pool: u.pool.name,
        name: u.name,
        username: u.sysusername,
        groupname: u.sysgroupname,
        ugid: u.ugid,
        homedir: u.homedir,
        registered: u.registered?,
        standalone: u.standalone,
        uid_map: u.uid_map.map(&:to_h),
        gid_map: u.gid_map.map(&:to_h)
      }.merge!(u.attrs.export))
    end
  end
end
