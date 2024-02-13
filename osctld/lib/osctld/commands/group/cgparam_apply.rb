require 'osctld/commands/base'

module OsCtld
  class Commands::Group::CGParamApply < Commands::Base
    handle :group_cgparam_apply

    include OsCtl::Lib::Utils::Log
    include Utils::CGroupParams

    def execute
      grp = DB::Groups.find(opts[:name], opts[:pool])
      return error('group not found') unless grp

      force = grp.any_container_running?

      grp.groups_in_path.each do |g|
        do_apply(g, force)
      end

      ok
    end

    protected

    def do_apply(grp, force)
      log(:info, grp, "Configuring group '#{grp.path}'")
      apply(grp, force:)
    end
  end
end
