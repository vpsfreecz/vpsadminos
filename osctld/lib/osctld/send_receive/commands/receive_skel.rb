require 'tempfile'
require 'osctld/send_receive/commands/base'

module OsCtld
  class SendReceive::Commands::ReceiveSkel < SendReceive::Commands::Base
    handle :receive_skel

    def execute
      client.send({status: true, response: 'continue'}.to_json + "\n", 0)

      io = client.recv_io
      f = Tempfile.open('ct-skel')
      f.write(io.readpartial(16*1024)) until io.eof?

      f.seek(0)

      pool = DB::Pools.get_or_default(opts[:pool])
      error!('pool not found') unless pool
      error!('the pool is disabled') unless pool.active?

      importer = Container::Importer.new(pool, f)
      data = importer.load_metadata

      if data['type'] != 'skel'
        error!("expected archive type to be 'skel', got '#{data['type']}'")
      end

      ct = importer.load_ct(ct_opts: {staged: true, devices: false})
      ct.manipulate(self) do
        builder = Container::Builder.new(ct, cmd: self)

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
        builder.setup_ct_dir
        builder.setup_lxc_home

        ct.open_send_log(:destination)
        builder.setup_lxc_configs
        builder.setup_log_file
        builder.setup_user_hook_script_dir
        importer.install_user_hook_scripts(ct)
        builder.monitor

        if ct.netifs.any?
          progress('Reconfiguring LXC usernet')
          call_cmd(Commands::User::LxcUsernet)
        end
      end

      ok

    ensure
      f.close
      f.unlink
    end
  end
end
