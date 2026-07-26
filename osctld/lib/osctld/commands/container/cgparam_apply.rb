require 'osctld/commands/base'

module OsCtld
  class Commands::Container::CGParamApply < Commands::Base
    handle :ct_cgparam_apply

    include OsCtl::Lib::Utils::Log
    include Utils::CGroupParams

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      log(:info, ct, 'Configuring cgroups')

      group_opts = {
        name: ct.group.name,
        pool: ct.pool.name
      }
      group_opts[:skip_cpuset] = true if opts[:skip_cpuset]
      ret = call_cmd(Commands::Group::CGParamApply, **group_opts)
      return ret unless ret[:status]

      ret = apply(
        ct,
        force: ct.running?,
        cpuset: !opts[:skip_cpuset]
      )
      return ret unless ret[:status]

      ok
    end
  end
end
