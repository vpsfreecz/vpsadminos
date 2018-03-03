module OsCtld
  class Commands::Group::CGParamApply < Commands::Base
    handle :group_cgparam_apply

    include OsCtl::Lib::Utils::Log
    include Utils::CGroupParams

    def execute
      grp = DB::Groups.find(opts[:name], opts[:pool])
      return error('group not found') unless grp

      force = any_container_running?(grp)

      grp.groups_in_path.each do |g|
        do_apply(g, force)
      end

      ok
    end

    protected
    def do_apply(grp, force)
      log(:info, grp, "Configuring group '#{grp.path}'")
      apply(grp, force: force)
    end

    def any_container_running?(grp)
      ct = grp.containers.detect { |ct| ct.state == :running }
      ct ? true : false
    end
  end
end
