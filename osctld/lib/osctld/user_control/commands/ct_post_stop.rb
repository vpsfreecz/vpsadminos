require 'libosctl'
require 'osctld/bpf_fs'
require 'osctld/container/stop_handler'
require 'osctld/user_control/commands/base'

module OsCtld
  class UserControl::Commands::CtPostStop < UserControl::Commands::Base
    handle :ct_post_stop

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::Exception

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct
      return error('access denied') unless owns_ct?(ct)

      if AppArmor.enabled?
        # Unload AppArmor profile and destroy namespace
        ct.apparmor.destroy_namespace
        ct.apparmor.unload_profile
      end

      if opts[:target] == 'reboot'
        log(:info, ct, 'Reboot requested')
        ct.run_conf.request_reboot
      end

      BpfFs.remove_ct(ct.pool.name, ct.id)
      run_conf = ct.run_conf
      ct.stopped(run_conf)

      # User-defined hook
      begin
        Hook.run(ct, :post_stop)
      ensure
        # Direct lxc-start has no tty0 wrapper to trigger exit cleanup. Use the
        # same handler, with exact run identity and once-only ownership, instead
        # of fulfilling the stop promise before cleanup has actually finished.
        if run_conf && !Console.handles_run?(ct, run_conf)
          Container::StopHandler.schedule(ct, run_conf)
        end
      end

      ok
    rescue HookFailed => e
      log(:warn, ct, 'Error during post-stop hook')
      log(:warn, ct, "#{e.class}: #{e.message}")
      log(:warn, ct, denixstorify(e.backtrace).join("\n"))
      error(e.message)
    end
  end
end
