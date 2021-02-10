require 'resolv'
require 'tempfile'
require 'osctld/send_receive/commands/base'

module OsCtld
  class SendReceive::Commands::ReceiveSkel < SendReceive::Commands::Base
    handle :receive_skel

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    def execute
      client.send({status: true, response: 'continue'}.to_json + "\n", 0)

      io = client.recv_io
      f = Tempfile.open('ct-skel')
      f.write(io.readpartial(16*1024)) until io.eof?

      f.seek(0)

      # sshd will use the first key that matches to accept the client. However,
      # one key can be authorized multiple times, either on different pools,
      # or even within the same pool, but with a different passphrase. We must
      # therefore find the matching key and target pool.
      pool, auth_key = find_pool_and_key

      error!('the pool is disabled') unless pool.active?

      importer = Container::Importer.new(pool, f)
      data = importer.load_metadata
      token = nil

      if data['type'] != 'skel'
        error!("expected archive type to be 'skel', got '#{data['type']}'")
      end

      ct = importer.load_ct(ct_opts: {staged: true, devices: false})

      if auth_key.ctid && !File.fnmatch?(auth_key.ctid, ct.id)
        error!('access denied: invalid container id')
      end

      ct.manipulate(self) do
        builder = Container::Builder.new(ct.get_run_conf)

        unless builder.valid?
          error!("invalid id, allowed format: #{builder.id_chars}")
        end

        begin
          ct.devices.check_all_available!

        rescue DeviceNotAvailable, DeviceModeInsufficient => e
          error!(e.message)
        end

        unless builder.register
          error!("container #{pool.name}:#{ct.id} already exists")
        end

        ct.devices.init

        importer.create_datasets(builder)

        # Unmount all datasets before transfers
        ct.datasets.reverse.each { |ds| zfs(:umount, '', ds.name, valid_rcs: [1]) }

        builder.setup_lxc_home

        SendReceive.started_using_key(pool, auth_key.name)
        token = SendReceive::Tokens.get
        ct.open_send_log(
          :destination,
          token,
          key_name: auth_key.name,
        )

        builder.setup_lxc_configs
        builder.setup_log_file
        builder.setup_user_hook_script_dir
        importer.install_user_hook_scripts(ct)
        builder.monitor

        if ct.netifs.any?
          call_cmd(Commands::User::LxcUsernet)
        end
      end

      # Pass the token to the sender
      ok(token)

    ensure
      f.close
      f.unlink
    end

    protected
    def find_pool_and_key
      key_pool = DB::Pools.find(opts[:key_pool])
      error!('pool not found') unless key_pool

      auth_key = key_pool.send_receive_key_chain.get_key(opts[:key_name])
      error!('invalid authentication key') unless auth_key

      log(:info, "Authenticated using key #{key_pool.name}:#{auth_key.name}")

      to_pool = DB::Pools.find(opts[:pool] || opts[:key_pool])
      error!('pool not found') unless to_pool

      ptr = get_ptr(opts[:client_ip])
      log(:info, "Client IP #{opts[:client_ip]}, PTR #{ptr || 'not found'}")

      actual_key = to_pool.send_receive_key_chain.find_key(
        auth_key.pubkey,
        [opts[:client_ip], ptr].compact,
        opts[:passphrase],
      )
      error!('invalid authentication key') unless actual_key

      log(:info, "Found matching key #{to_pool.name}:#{actual_key.name}")

      if actual_key.single_use? && actual_key.in_use?
        log(:info, 'Key already in use')
        error!('invalid authentication key')
      end

      [to_pool, actual_key]
    end

    def get_ptr(addr)
      Resolv.getname(addr)
    rescue Resolv::ResolvError
      nil
    end
  end
end
