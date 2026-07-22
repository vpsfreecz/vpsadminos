require 'libosctl'
require 'osctld/user_control/commands/base'

module OsCtld
  class UserControl::Commands::CtWrapperStart < UserControl::Commands::Base
    handle :ct_wrapper_start

    include OsCtl::Lib::Utils::Log

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      ret = authenticate_run_callback(ct)
      return ret if ret

      lifecycle_start_token = opts[:lifecycle_start_token]
      unless lifecycle_start_token.is_a?(String) && !lifecycle_start_token.empty?
        return error('missing lifecycle start capability')
      end

      unless peer_in_container_cgroup?(ct)
        return error('lifecycle process is not in the container cgroup')
      end

      ret = with_authenticated_run(ct) do |run_conf|
        # Consume the exact run capability and publish the lifecycle identity
        # while the container's current-run pointer is still locked. Any
        # privileged effect below is therefore unreachable to invalid,
        # replayed, or already-registered requests. A later effect failure is
        # deliberately not replayable.
        run_conf.register_lifecycle(
          peer,
          token: lifecycle_start_token
        )

        # Reset oom_score_adj of the calling process. The reset has to come
        # from a process with CAP_SYS_RESOURCE (which osctld is), so that
        # oom_score_adj_min is changed and container users cannot freely set
        # oom_score_adj to -1000.
        log(:debug, ct, "Set /proc/#{peer.pid}/oom_score_adj=0")
        peer.open_proc_file('oom_score_adj', 'w') { |f| f.write('0') }
      end
      return ret if ret

      ok
    rescue Container::RunConfiguration::LifecycleError => e
      error(e.message)
    end
  end
end
