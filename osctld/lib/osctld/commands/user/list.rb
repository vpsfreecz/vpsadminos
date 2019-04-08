require 'osctld/commands/base'

module OsCtld
  class Commands::User::List < Commands::Base
    handle :user_list

    def execute
      ret = []

      DB::Users.get.each do |u|
        next if opts[:pool] && !opts[:pool].include?(u.pool.name)
        next if opts[:names] && !opts[:names].include?(u.name)
        next if opts.has_key?(:registered) && u.registered? != opts[:registered]

        ret << {
          pool: u.pool.name,
          name: u.name,
          username: u.sysusername,
          groupname: u.sysgroupname,
          type: u.type.to_s,
          ugid: u.ugid,
          homedir: u.homedir,
          registered: u.registered?,
        }.merge!(u.attrs.export)
      end

      ok(ret)
    end
  end
end
