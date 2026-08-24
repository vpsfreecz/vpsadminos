require 'libosctl'
require 'osctld/send_receive/commands/base'
require 'osctld/utils/container'

module OsCtld
  class SendReceive::Commands::Transfer < SendReceive::Commands::Base
    handle :receive_transfer

    include Utils::Receive
    include Utils::Container
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    def execute
      ct = SendReceive::Tokens.find_container(opts[:token])
      error!('container not found') unless ct
      error!('the pool is disabled') unless ct.pool.active?

      ct.manipulate(self, block: true) do
        error!('this container is not staged') if ct.config_state != :staged

        if !ct.send_log || !ct.send_log.can_receive_continue?(:transfer)
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

        begin
          ct.complete_staging

          if opts[:start]
            call_cmd!(
              Commands::Container::Start,
              id: ct.id,
              pool: ct.pool.name,
              force: true
            )
          end
        rescue StandardError
          rollback_failed_receive_transfer(ct)
          raise
        end

        ct.exclusively do
          ct.send_log.state = :transfer
          ct.save_config
        end
      end

      ok
    end

    protected

    def rollback_failed_receive_transfer(ct)
      Console.remove(ct)
      ct.clear_start_menu
      ct.mounts.shared_dir.remove
      ct.mounts.prune
      ct.unmount(force: true)
      remove_accounting_cgroups(ct)

      if AppArmor.enabled?
        ct.apparmor.destroy_namespace
        ct.apparmor.unload_profile
      end

      ct.stopped
      ct.stage
    end
  end
end
