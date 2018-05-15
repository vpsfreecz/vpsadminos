require 'osctld/commands/base'

module OsCtld
  class Commands::Group::Show < Commands::Base
    handle :group_show

    def execute
      grp = DB::Groups.find(opts[:name], opts[:pool])
      return error('group not found') unless grp

      grp.inclusively do
        ok({
          pool: grp.pool.name,
          name: grp.name,
          path: grp.path,
          full_path: grp.cgroup_path,
        })
      end
    end
  end
end
