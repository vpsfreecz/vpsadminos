module OsCtld
  class Commands::Group::ParamApply < Commands::Base
    handle :group_param_apply

    include Utils::Log

    def execute
      grp = GroupList.find(opts[:name])
      return error('group not found') unless grp

      force = any_container_running?(grp)
      apply(GroupList.root, force)

      path = ''

      grp.path.split('/').each do |name|
        path = File.join(path, name)
        path = path[1..-1] if path.start_with?('/')

        g = GroupList.by_path(path)
        next unless g

        apply(g, force)
      end

      ok
    end

    protected
    def apply(grp, force)
      log(
        :info,
        "Group #{grp.name}",
        "Configuring cgroup '#{grp.cgroup_path}'"
      )

      grp.params.each do |p|
        path = File.join(grp.abs_cgroup_path(p.subsystem), p.name)

        if File.exist?(path)
          log(:info, "Group #{grp.name}", "Set #{path}=#{p.value}")

          begin
            File.write(path, p.value.to_s)

          rescue => e
            log(
              :warn,
              "Group #{grp.name}",
              "Unable to set #{path}=#{p.value}: #{e.message}"
            )
          end

          next
        end

        fail "Unable to set #{path}=#{p.value}: parameter not found" if force
        log(
          :info,
          "Group #{grp.name}",
          "Skip #{path}, group does not exist and no container is running"
        )
      end
    end

    def any_container_running?(grp)
      ct = grp.containers.detect { |ct| ct.state == :running }
      ct ? true : false
    end
  end
end
