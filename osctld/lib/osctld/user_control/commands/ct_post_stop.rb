require 'libosctl'
require 'osctld/bpf_fs'
require 'osctld/user_control/commands/base'

module OsCtld
  class UserControl::Commands::CtPostStop < UserControl::Commands::Base
    handle :ct_post_stop

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::Exception

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      ret = authenticate_lifecycle_callback(ct)
      return ret if ret

      begin
        target = peer.environment_variable('LXC_TARGET').to_s
      rescue SystemCallError, IOError, ArgumentError => e
        return error("unable to resolve container stop target: #{e.message}")
      end
      return error('invalid container stop target') unless %w[stop reboot].include?(target)

      # LXC can reach post-stop before pre-start when initialization fails.
      # The registered lifecycle and one-shot wrapper event are sufficient to
      # authorize cleanup for that failed run.
      with_claimed_lifecycle_event(
        ct,
        :post_stop,
        after: :wrapper_start
      ) do |run_conf|
        if target == 'reboot'
          log(:info, ct, 'Reboot requested')
          run_conf.request_reboot
        end

        teardown_failures = []
        accepted = ct.stopped(run_conf) do |teardown_owner|
          begin
            # BPF cleanup belongs to authenticated post-stop and must complete
            # even when recovery owns the common teardown.
            capture_teardown_failure(teardown_failures, :bpf) do
              BpfFs.remove_ct(ct.pool.name, ct.id)
            end
          ensure
            release_lifecycle_event_lease
          end

          next unless teardown_owner

          # Retirement rejects new leases. Wait for every already-admitted
          # path-specific effect before running common teardown effects.
          capture_teardown_failure(teardown_failures, :lifecycle_leases) do
            run_conf.wait_for_lifecycle_leases
          end

          if AppArmor.enabled?
            capture_teardown_failure(teardown_failures, :apparmor_namespace) do
              ct.apparmor.destroy_namespace
            end
            capture_teardown_failure(teardown_failures, :apparmor_profile) do
              ct.apparmor.unload_profile
            end
          end

          capture_teardown_failure(teardown_failures, :post_stop_hook) do
            Hook.run(ct, :post_stop)
          end
        end

        next error('stale container run') unless accepted

        raise_teardown_failure(ct, teardown_failures)

        ok
      end
    rescue HookFailed => e
      log(:warn, ct, 'Error during post-stop hook')
      log(:warn, ct, "#{e.class}: #{e.message}")
      log(:warn, ct, denixstorify(e.backtrace).join("\n"))
      error(e.message)
    end

    protected

    def capture_teardown_failure(failures, step)
      yield
    rescue StandardError => e
      failures << [step, e]
    end

    def raise_teardown_failure(ct, failures)
      return if failures.empty?

      failures.drop(1).each do |step, error|
        log(:warn, ct, "Additional #{step} teardown failure: #{error.class}: #{error.message}")
      rescue StandardError
        # Preserve the first teardown error even if secondary logging fails.
      end

      raise failures.first.last
    end
  end
end
