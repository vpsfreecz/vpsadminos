require 'osctld/commands/base'
require 'open3'

module OsCtld
  class Commands::Container::SendCancel < Commands::Base
    handle :ct_send_cancel

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include OsCtl::Lib::Utils::Send

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      error!('container not found') unless ct

      ct.exclusively do
        if !ct.send_log || !ct.send_log.can_continue?(:cancel)
          error!('invalid send sequence')
        end

        ret = system(
          *send_ssh_cmd(
            ct.pool.migration_key_chain,
            ct.send_log.opts,
            ['receive', 'cancel', ct.id]
          )
        )

        if ret.nil? || $?.exitstatus != 0 && !opts[:force]
          error!('cancel failed')
        end

        ct.each_dataset do |ds|
          ct.send_log.snapshots.each do |snap|
            zfs(:destroy, nil, "#{ds}@#{snap}")
          end
        end

        ct.close_send_log
      end

      ok
    end
  end
end
