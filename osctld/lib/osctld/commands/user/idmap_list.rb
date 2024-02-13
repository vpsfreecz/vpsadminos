require 'osctld/commands/base'

module OsCtld
  class Commands::User::IdMapList < Commands::Base
    handle :user_idmap_list

    def execute
      u = DB::Users.find(opts[:name], opts[:pool])
      return error('user not found') unless u

      maps = []
      maps << [:uid, u.uid_map] if opts[:uid]
      maps << [:gid, u.gid_map] if opts[:gid]

      ret = []

      maps.each do |type, map|
        map.each do |entry|
          ret << {
            type:,
            ns_id: entry.ns_id,
            host_id: entry.host_id,
            count: entry.count
          }
        end
      end

      ok(ret)
    end
  end
end
