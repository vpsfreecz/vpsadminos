module OsCtld
  class Commands::Group::Assets < Commands::Assets
    handle :group_assets

    def execute
      grp = GroupList.find(opts[:name])
      return error('group not found') unless grp

      add(:file, grp.config_path, "osctld's group config")

      grp.users.each do |u|
        dir = grp.userdir(u)

        add(:directory, dir, "LXC path for #{u.name}/#{grp.name}")
      end

      ok(assets)
    end
  end
end
