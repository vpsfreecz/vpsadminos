require 'tempfile'

module OsCtld
  class Migration::Commands::ReceiveSkel < Migration::Commands::Base
    handle :receive_skel

    def execute
      client.send({status: true, response: 'continue'}.to_json + "\n", 0)

      io = client.recv_io
      f = Tempfile.open('ct-skel')
      f.write(io.readpartial(16*1024)) until io.eof?

      f.seek(0)

      pool = DB::Pools.get_or_default(opts[:pool])
      error!('pool not found') unless pool

      importer = Container::Importer.new(pool, f)
      data = importer.load_metadata

      if data['type'] != 'skel'
        error!("expected archive type to be 'skel', got '#{data['type']}'")

      elsif DB::Containers.find(data['container'], pool)
        error!("container #{pool.name}:#{data['container']} already exists")
      end

      ct = importer.load_ct(ct_opts: {staged: true})
      builder = Container::Builder.new(ct, cmd: self)

      unless builder.valid?
        error!("invalid id, allowed format: #{builder.id_chars}")
      end

      builder.create_dataset(offset: true)
      builder.setup_ct_dir
      builder.setup_lxc_home

      ct.open_migration_log(:destination, save: true)
      builder.setup_lxc_configs
      builder.setup_log_file
      builder.register

      if ct.netifs.any?
        progress('Reconfiguring LXC usernet')
        call_cmd(Commands::User::LxcUsernet)
      end

      ok

    ensure
      f.close
      f.unlink
    end
  end
end
