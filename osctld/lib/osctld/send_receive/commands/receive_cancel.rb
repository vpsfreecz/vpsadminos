require 'osctld/send_receive/commands/base'

module OsCtld
  class SendReceive::Commands::ReceiveCancel < SendReceive::Commands::Base
    handle :receive_cancel

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      error!('container not found') unless ct

      ct.manipulate(self, block: true) do
        error!('this container is not staged') if ct.state != :staged

        if !ct.send_log || !ct.send_log.can_receive_cancel?
          error!('invalid send sequence')
        end

        ct.send_log.snapshots.each do |v|
          ds, snap = v
          zfs(:destroy, nil, "#{ds}@#{snap}")
        end

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
end
