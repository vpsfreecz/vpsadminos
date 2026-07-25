require 'osctld/commands/container/local_transfer/base'

module OsCtld
  class Commands::Container::LocalTransfer::State < Commands::Container::LocalTransfer::Base
    def execute(ct)
      manipulate(ct) do
        log = prepare_state!(ct)
        running = log.state_running
        stopped = stop_source_for_state?(running)

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
      log = ct.exclusively do
        ret = require_local_transfer_log!(ct)
        unless %i[base incremental].include?(ret.state) && ret.can_local_continue?(:transfer)
          error!('invalid local transfer sequence')
        end

        if ret.state_running.nil?
          ret.state_running = ct.state == :running
          ct.save_config
        end

        ret
      end

      ensure_target_staged_or_complete!(log)
      validate_dataset_layout!(ct)
      log
    end

    def stop_source_for_state?(_running)
      raise NotImplementedError
    end

    def after_state_snapshot(_ct, _running, _stopped); end

    def after_target_complete(_log, _running); end
  end
end
