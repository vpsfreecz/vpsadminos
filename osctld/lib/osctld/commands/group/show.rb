module OsCtld
  class Commands::Group::Show < Commands::Base
    handle :group_show

    def execute
      grp = DB::Groups.find(opts[:name])
      return error('group not found') unless grp

      grp.inclusively do
        ok({
          name: grp.name,
          path: grp.path,
        })
      end
    end
  end
end
