module OsCtld
  class Commands::Group::CGParamApply < Commands::Base
    handle :group_cgparam_apply

    include Utils::Log
    include Utils::CGroupParams

    def execute
      grp = GroupList.find(opts[:name])
      return error('group not found') unless grp

      force = any_container_running?(grp)

      each_group_in(grp.path) do |g|
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
