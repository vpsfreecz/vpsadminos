module OsCtld
  class Commands::Group::CGParamApply < Commands::Base
    handle :group_cgparam_apply

    include Utils::Log
    include Utils::CGroupParams

    def execute
      grp = GroupList.find(opts[:name])
      return error('group not found') unless grp

      force = any_container_running?(grp)
      do_apply(GroupList.root, force)

      path = ''

      grp.path.split('/').each do |name|
        path = File.join(path, name)
        path = path[1..-1] if path.start_with?('/')

        g = GroupList.by_path(path)
        next unless g

        do_apply(g, force)
      end

      ok
    end

    protected
    def do_apply(grp, force)
      log(
        :info,
        "Group #{grp.name}",
        "Configuring group '#{grp.path}'"
      )
      apply(grp, force: force)
    end

    def any_container_running?(grp)
      ct = grp.containers.detect { |ct| ct.state == :running }
      ct ? true : false
    end
  end
end
