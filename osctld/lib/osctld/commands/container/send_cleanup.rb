require 'osctld/commands/base'

module OsCtld
  class Commands::Container::SendCleanup < Commands::Base
    handle :ct_send_cleanup

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      error!('container not found') unless ct

      manipulate(ct) do
        ct.exclusively do
          if !ct.send_log || !ct.send_log.can_continue?(:cleanup)
            error!('invalid send sequence')
          end
        end

        ct.each_dataset do |ds|
          ct.send_log.snapshots.each do |snap|
            zfs(:destroy, nil, "#{ds}@#{snap}")
          end
        end

        cloned = ct.send_log.opts.cloned?
        ct.close_send_log

        unless cloned
          call_cmd!(
            Commands::Container::Delete,
            pool: ct.pool.name,
            id: ct.id
          )
        end

        ok
      end
    end
  end
end
