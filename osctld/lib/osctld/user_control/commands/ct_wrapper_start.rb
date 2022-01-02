require 'libosctl'
require 'osctld/user_control/commands/base'

module OsCtld
  class UserControl::Commands::CtWrapperStart < UserControl::Commands::Base
    handle :ct_wrapper_start

    include OsCtl::Lib::Utils::Log

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct
      return error('access denied') unless owns_ct?(ct)

      # Move the calling wrapper to user-owned cgroup, which will then be used
      # by LXC
      CGroup.subsystems.each do |subsys|
        CGroup.mkpath(
          subsys,
          ct.cgroup_path.split('/'),
          chown: ct.user.ugid,
          attach: true,
          pid: opts[:pid],
        )
      end

      # Reset oom_score_adj of the calling process. The reset has to come from
      # a process with CAP_SYS_RESOURCE (which osctld is), so that
      # oom_score_adj_min is changed and container users cannot freely set
      # oom_score_adj to -1000.
      log(:debug, "Set /proc/#{opts[:pid]}/oom_score_adj=0")
      File.open(File.join('/proc', opts[:pid].to_s, 'oom_score_adj'), 'w') do |f|
        f.write('0')
      end

      ok
    end
  end
end
