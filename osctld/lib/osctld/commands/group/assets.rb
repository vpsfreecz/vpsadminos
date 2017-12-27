module OsCtld
  class Commands::Group::Assets < Commands::Assets
    handle :group_assets

    def execute
      grp = GroupList.find(opts[:name])
      return error('group not found') unless grp

      add(:file, grp.config_path, "osctld's group config")

      grp.users.each do |u|
        dir = grp.lxc_home(u)

        add(:directory, dir, "LXC path for #{u.name}/#{grp.name}")
        add(
          :file,
          File.join(dir, '.bashrc'),
          'Shell configuration file for osctl ct su'
        )
      end

      ok(assets)
    end
  end
end
