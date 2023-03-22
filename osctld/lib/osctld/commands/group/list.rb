require 'osctld/commands/base'

module OsCtld
  class Commands::Group::List < Commands::Base
    handle :group_list

    def execute
      ret = []

      DB::Groups.each_by_ids(opts[:names], opts[:pool]) do |grp|
        grp.inclusively do
          ret << {
            pool: grp.pool.name,
            name: grp.name,
            path: grp.path,
            full_path: grp.cgroup_path,
          }.merge!(grp.attrs.export)
        end
      end

      ok(ret)
    end
  end
end
