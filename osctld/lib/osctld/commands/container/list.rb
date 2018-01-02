module OsCtld
  class Commands::Container::List < Commands::Base
    handle :ct_list

    include Utils::Log
    include Utils::System
    include Utils::SwitchUser

    def execute
      ret = []

      DB::Containers.get.each do |ct|
        next if opts[:ids] && !opts[:ids].include?(ct.id)
        next unless include?(ct)

        ct.inclusively do
          ret << {
            pool: ct.pool.name,
            id: ct.id,
            user: ct.user.name,
            group: ct.group.name,
            dataset: ct.dataset,
            rootfs: ct.rootfs,
            lxc_path: ct.lxc_home,
            lxc_dir: ct.lxc_dir,
            group_path: ct.cgroup_path,
            distribution: ct.distribution,
            version: ct.version,
            state: ct.state,
            init_pid: ct.init_pid,
            nesting: ct.nesting,
          }
        end
      end

      ok(ret)
    end

    protected
    def include?(ct)
      return false if opts[:pool] && !opts[:pool].include?(ct.pool.name)
      return false if opts[:user] && !opts[:user].include?(ct.user.name)
      return false if opts[:group] && !opts[:group].include?(ct.group.name)
      return false if opts[:distribution] && !opts[:distribution].include?(ct.distribution)
      return false if opts[:version] && !opts[:version].include?(ct.version)
      return false if opts[:state] && !opts[:state].include?(ct.state.to_s)
      true
    end
  end
end
