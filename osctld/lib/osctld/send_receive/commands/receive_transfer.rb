require 'libosctl'
require 'osctld/send_receive/commands/base'

module OsCtld
  class SendReceive::Commands::Transfer < SendReceive::Commands::Base
    handle :receive_transfer

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      error!('container not found') unless ct
      error!('the pool is disabled') unless ct.pool.active?

      ct.manipulate(self, block: true) do
        error!('this container is not staged') if ct.state != :staged

        if !ct.send_log || !ct.send_log.can_receive_continue?(:transfer)
          error!('invalid send sequence')
        end

        ct.state = :complete

        # FIXME: the datasets are in some strange state, ZFS thinks they're
        # mounted, but it's not so. First, unmount all of them. Some will report
        # `umount: <mountpoint>: no mount point specified` and some won't be
        # mounted at all, so ignore exit code `1`. Then remount them.
        datasets = ct.datasets
        datasets.reverse.each { |ds| zfs(:umount, '', ds.name, valid_rcs: [1]) }
        datasets.each { |ds| zfs(:mount, '', ds.name) }

        call_cmd!(
          Commands::Container::Start,
          id: ct.id,
          pool: ct.pool.name,
          force: true
        ) if opts[:start]

        ct.send_log.snapshots.each do |v|
          ds, snap = v
          zfs(:destroy, nil, "#{ds}@#{snap}")
        end

        ct.close_send_log
      end

      ok
    end
  end
end
