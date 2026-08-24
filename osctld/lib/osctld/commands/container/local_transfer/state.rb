require 'osctld/commands/container/local_transfer/base'

module OsCtld
  class Commands::Container::LocalTransfer::State < Commands::Container::LocalTransfer::Base
    def execute(ct)
      manipulate(ct) do
        log, running, stopped = prepare_state!(ct)

        if stopped
          guard_residual_generations!(
            ct,
            'consistent local container transfer'
          )
          call_cmd!(Commands::Container::Stop, id: ct.id, pool: ct.pool.name)
          guard_no_runtime_generations!(
            ct,
            'consistent local container transfer'
          )
          force_writeout(ct)
        elsif !running && (operation == :move || opts.fetch(:consistent, true))
          guard_no_runtime_generations!(
            ct,
            'consistent local container transfer'
          )
        end

        clear_failed_state_snapshot(ct, log)

        snap = snapshot_name(:state)
        snapshot_datasets(log, snap)

        ct.exclusively do
          ct.local_transfer_log.state_snapshot = snap
          ct.save_config
        end

        after_state_snapshot(ct, running, stopped)

        log.opts.datasets.each do |pair|
          transfer_dataset(pair, snap, from_snapshot: log.snapshots.last)
        end

        complete_target!(log)
        after_target_complete(log, running)

        ct.exclusively do
          ct.local_transfer_log.state = :transfer
          ct.save_config
        end
      end

      ok
    end

    protected

    def prepare_state!(ct)
      log, running, stopped, record_running = ct.exclusively do
        ret = require_local_transfer_log!(ct)
        unless %i[base incremental].include?(ret.state) && ret.can_local_continue?(:transfer)
          error!('invalid local transfer sequence')
        end

        observed_running = if ret.state_running.nil?
                             ct.runtime_state == :running
                           else
                             ret.state_running
                           end
        source_stopped = stop_source_for_state?(observed_running)
        preflight_state!(ct, observed_running, source_stopped)

        [ret, observed_running, source_stopped, ret.state_running.nil?]
      end

      ensure_target_staged_or_complete!(log)
      validate_dataset_layout!(ct)

      if record_running
        ct.exclusively do
          log.state_running = running
          ct.save_config
        end
      end

      [log, running, stopped]
    end

    def stop_source_for_state?(_running)
      raise NotImplementedError
    end

    def preflight_state!(_ct, _running, _stopped); end

    def after_state_snapshot(_ct, _running, _stopped); end

    def after_target_complete(_log, _running); end
  end
end
