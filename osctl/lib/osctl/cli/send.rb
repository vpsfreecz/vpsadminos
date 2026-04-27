require 'osctl/cli/command'
require 'osctl/cli/transfer_progress'

module OsCtl::Cli
  class Send < Command
    include TransferProgress

    def key_gen
      c = osctld_open

      unless opts[:force]
        ret = c.cmd_data!(:send_key_path, pool: gopts[:pool])

        %i[public_key private_key].each do |v|
          if File.exist?(ret[v])
            raise "File #{ret[v]} already exists, use -f, --force to overwrite"
          end
        end
      end

      c.cmd_data!(
        :send_key_gen,
        pool: gopts[:pool],
        type: opts[:type],
        bits: opts[:bits]
      )
    end

    def key_path
      if args[0] && !%w[public private].include?(args[0])
        raise GLI::BadCommandLine, "expected public/private, got '#{args[0]}'"
      end

      ret = osctld_call(:send_key_path, pool: gopts[:pool])

      if !args[0] || args[0] == 'public'
        puts ret[:public_key]

      else
        puts ret[:private_key]
      end
    end

    def config
      require_args!('id', 'dst')

      with_progress(
        :ct_send_config,
        pool: gopts[:pool],
        id: args[0],
        dst: args[1],
        port: opts[:port],
        passphrase: opts[:passphrase],
        as_id: opts['as-id'],
        as_user: opts['as-user'],
        as_group: opts['as-group'],
        to_pool: opts['to-pool'],
        network_interfaces: opts['network-interfaces'],
        snapshots: opts[:snapshots],
        from_snapshot: opts['from-snapshot'],
        preexisting_datasets: opts['preexisting-datasets']
      )
    end

    def rootfs
      require_args!('id')

      with_progress(
        :ct_send_rootfs,
        pool: gopts[:pool],
        id: args[0]
      )
    end

    def sync
      require_args!('id')

      with_progress(
        :ct_send_sync,
        pool: gopts[:pool],
        id: args[0]
      )
    end

    def state
      require_args!('id')

      with_progress(
        :ct_send_state,
        pool: gopts[:pool],
        id: args[0],
        clone: opts[:clone],
        consistent: opts[:consistent],
        restart: opts[:restart],
        start: opts[:start]
      )
    end

    def cleanup
      require_args!('id')

      with_progress(
        :ct_send_cleanup,
        pool: gopts[:pool],
        id: args[0]
      )
    end

    def cancel
      require_args!('id')

      with_progress(
        :ct_send_cancel,
        pool: gopts[:pool],
        id: args[0],
        force: opts[:force],
        local: opts[:local]
      )
    end

    def now
      require_args!('id', 'dst')

      with_progress(
        :ct_send_now,
        pool: gopts[:pool],
        id: args[0],
        dst: args[1],
        port: opts[:port],
        passphrase: opts[:passphrase],
        as_id: opts['as-id'],
        as_user: opts['as-user'],
        as_group: opts['as-group'],
        to_pool: opts['to-pool'],
        clone: opts[:clone],
        consistent: opts[:consistent],
        restart: opts[:restart],
        start: opts[:start],
        network_interfaces: opts['network-interfaces'],
        snapshots: opts[:snapshots],
        from_snapshot: opts['from-snapshot'],
        preexisting_datasets: opts['preexisting-datasets']
      )
    end
  end
end
