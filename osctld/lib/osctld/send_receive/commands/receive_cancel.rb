require 'osctld/send_receive/commands/base'

module OsCtld
  class SendReceive::Commands::ReceiveCancel < SendReceive::Commands::Base
    handle :receive_cancel

    include Utils::Receive
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    def execute
      ct = SendReceive::Tokens.find_container(opts[:token])
      error!('container not found') unless ct

      ct.manipulate(self, block: true) do
        error!('this container is not staged') if ct.state != :staged

        if !ct.send_log || !ct.send_log.can_receive_cancel?
          error!('invalid send sequence')
        elsif !check_auth_pubkey(
          opts[:key_pool],
          opts[:key_name],
          ct,
          key_pubkey_hash: opts[:key_pubkey_hash]
        )
          error!('authentication key mismatch')
        end

        validate_send_log_protocol!(ct)

        ct.send_log.snapshots.each do |v|
          ds, snap = v
          zfs(:destroy, nil, "#{ds}@#{snap}")
        end

        SendReceive.stopped_using_key(ct.pool, ct.send_log.opts.key_name)
        ct.close_send_log

        call_cmd!(
          Commands::Container::Delete,
          id: ct.id,
          pool: ct.pool.name
        )
      end

      ok
    end
  end

  class SendReceive::Commands::Cleanup < SendReceive::Commands::Base
    handle :receive_cleanup

    include Utils::Receive
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    def execute
      ct = SendReceive::Tokens.find_container(opts[:token])
      error!('container not found') unless ct
      error!('the pool is disabled') unless ct.pool.active?

      ct.manipulate(self, block: true) do
        if !ct.send_log || !ct.send_log.can_receive_continue?(:cleanup)
          error!('invalid send sequence')
        elsif !check_auth_pubkey(
          opts[:key_pool],
          opts[:key_name],
          ct,
          key_pubkey_hash: opts[:key_pubkey_hash]
        )
          error!('authentication key mismatch')
        end

        validate_send_log_protocol!(ct)

        ct.exclusively do
          ct.send_log.state = :cleanup
          ct.save_config
        end

        ct.send_log.snapshots.each do |ds, snap|
          zfs(:destroy, nil, "#{ds}@#{snap}", valid_rcs: [1])
        end

        SendReceive.stopped_using_key(ct.pool, ct.send_log.opts.key_name)
        ct.close_send_log
      end

      ok
    end
  end
end
