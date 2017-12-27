module OsCtld
  class Commands::Group::Delete < Commands::Base
    handle :group_delete

    def execute
      GroupList.sync do
        grp = GroupList.find(opts[:name])
        return error('group not found') unless grp
        return error('group is used by containers') if grp.has_containers?

        grp.exclusively do
          # Double-check user's containers, for only within the lock
          # can we be sure
          return error('group is used by containers') if grp.has_containers?

          File.unlink(grp.config_path)
        end

        GroupList.remove(grp)
      end

      ok
    end
  end
end
