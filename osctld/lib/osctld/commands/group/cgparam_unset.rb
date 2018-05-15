require 'osctld/commands/logged'

module OsCtld
  class Commands::Group::CGParamUnset < Commands::Logged
    handle :group_cgparam_unset
    include Utils::CGroupParams

    def find
      grp = DB::Groups.find(opts[:name], opts[:pool])
      grp || error!('group not found')
    end

    def execute(grp)
      unset(grp, opts, reset: true, keep_going: true)
    end
  end
end
