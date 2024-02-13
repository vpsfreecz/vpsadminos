require 'osctld/commands/base'

module OsCtld
  class Commands::User::List < Commands::Base
    handle :user_list

    def execute
      ret = []

      DB::Users.each_by_ids(opts[:names], opts[:pool]) do |u|
        next if opts.has_key?(:registered) && u.registered? != opts[:registered]

        ret << {
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
        }.merge!(u.attrs.export)
      end

      ok(ret)
    end
  end
end
