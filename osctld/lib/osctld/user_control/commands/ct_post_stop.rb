require 'libosctl'
require 'osctld/eventd'
require 'osctld/user_control/commands/base'

module OsCtld
  class UserControl::Commands::CtPostStop < UserControl::Commands::Base
    handle :ct_post_stop
    allow_adopted_legacy_callbacks

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::Exception

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct
      return error('access denied') unless owns_ct?(ct)

      run_conf = lifecycle_run_conf(ct)
      return error('managed lifecycle run not found') unless run_conf

      execution_run = ct.lifecycle.execution_run?(run_conf.run_id)

      if opts[:target] == 'reboot' && !execution_run
        log(:info, ct, 'Reboot requested')
        run_conf.request_reboot
      end

      return error('managed lifecycle run changed') unless ct.stopped(run_conf.run_id)

      effect_id = ct.lifecycle.observe_post_stop(
        run_conf.run_id,
        aborted: run_conf.aborted?,
        reboot: opts[:target] == 'reboot' && !execution_run
      )
      run = ct.lifecycle.run(run_conf.run_id)
      return error('managed lifecycle run changed') unless run&.fetch('post_stop', false)

      unless execution_run
        Eventd.report(
          :state,
          pool: ct.pool.name,
          id: ct.id,
          state: :stopped
        )
      end
      Container::LifecycleFinalizer.spawn(ct, run_conf, effect_id) if effect_id

      ok
    end
  end
end
