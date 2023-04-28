require 'osctld/commands/base'

module OsCtld
  class Commands::Group::Show < Commands::Base
    handle :group_show

    def execute
      grp = DB::Groups.find(opts[:name], opts[:pool])
      return error('group not found') unless grp

      grp.inclusively do
        ok(grp.export.merge!(grp.attrs.export))
      end
    end
  end
end
