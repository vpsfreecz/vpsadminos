require 'osctld/commands/base'

module OsCtld
  class Commands::Group::List < Commands::Base
    handle :group_list

    def execute
      ret = []

      DB::Groups.get.each do |grp|
        next if opts[:pool] && !opts[:pool].include?(grp.pool.name)
        next if opts[:names] && !opts[:names].include?(grp.name)

        grp.inclusively do
          ret << {
            pool: grp.pool.name,
            name: grp.name,
            path: grp.path,
            full_path: grp.cgroup_path,
          }
        end
      end

      ok(ret)
    end
  end
end
