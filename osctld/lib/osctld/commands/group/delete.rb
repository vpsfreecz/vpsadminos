module OsCtld
  class Commands::Group::Delete < Commands::Logged
    handle :group_delete

    def find
      grp = DB::Groups.find(opts[:name], opts[:pool])
      error!('group not found') unless grp
      error!('group is used by containers') if grp.has_containers?
      error!('group has children') if grp.children.any?
      grp
    end

    def execute(grp)
      DB::Groups.sync do
        grp.exclusively do
          # Double-check user's containers, for only within the lock
          # can we be sure
          error!('group is used by containers') if grp.has_containers?
          error!('group has children') if grp.children.any?

          File.unlink(grp.config_path)
          Dir.rmdir(grp.config_dir)
        end

        DB::Groups.remove(grp)
      end

      ok
    end
  end
end
