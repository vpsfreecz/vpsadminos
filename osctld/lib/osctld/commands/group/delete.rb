module OsCtld
  class Commands::Group::Delete < Commands::Base
    handle :group_delete

    def execute
      DB::Groups.sync do
        grp = DB::Groups.find(opts[:name])
        return error('group not found') unless grp
        return error('group is used by containers') if grp.has_containers?

        grp.exclusively do
          # Double-check user's containers, for only within the lock
          # can we be sure
          return error('group is used by containers') if grp.has_containers?

          File.unlink(grp.config_path)
        end

        DB::Groups.remove(grp)
      end

      ok
    end
  end
end
