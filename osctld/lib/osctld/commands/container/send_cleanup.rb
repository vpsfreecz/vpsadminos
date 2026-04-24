require 'osctld/commands/base'

module OsCtld
  class Commands::Container::SendCleanup < Commands::Base
    handle :ct_send_cleanup

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include OsCtl::Lib::Utils::Send

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      error!('container not found') unless ct

      manipulate(ct) do
        ct.exclusively do
          if !ct.send_log || !ct.send_log.can_send_continue?(:cleanup)
            error!('invalid send sequence')
          end
        end

        cleanup_target(ct) if ct.send_log.state == :transfer

        ct.exclusively do
          ct.send_log.state = :cleanup
          ct.save_config
        end

        destroy_send_snapshots(ct)

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

    protected

    def destroy_send_snapshots(ct)
      ct.each_dataset do |ds|
        ct.send_log.snapshots.each do |snap|
          zfs(:destroy, nil, "#{ds}@#{snap}", valid_rcs: [1])
        end

        next if ct.send_log.state_snapshot.nil?

        zfs(:destroy, nil, "#{ds}@#{ct.send_log.state_snapshot}", valid_rcs: [1])
      end
    end

    def cleanup_target(ct)
      ret = system(
        *send_ssh_cmd(
          ct.pool.send_receive_key_chain,
          ct.send_log.opts,
          ['receive', 'cleanup', ct.send_log.token]
        )
      )

      error!('cleanup failed') if ret.nil? || $?.exitstatus != 0
    end
  end
end
