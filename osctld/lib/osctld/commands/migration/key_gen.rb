module OsCtld
  class Commands::Migration::KeyGen < Commands::Logged
    handle :migration_key_gen

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    def find
      if opts[:pool]
        pool = DB::Pools.find(opts[:pool])

      else
        pool = DB::Pools.get_or_default(nil)
      end

      pool || error!('pool not found')
    end

    def execute(pool)
      privkey = pool.migration_key_chain.private_key_path
      pubkey = pool.migration_key_chain.public_key_path

      [privkey, pubkey].each do |v|
        File.unlink(v) if File.exist?(v)
      end

      type = opts[:type] || 'rsa'

      if opts[:bits]
        bits = opts[:bits]

      elsif type == 'ecdsa'
        bits = 521

      else
        bits = 4096
      end

      syscmd("ssh-keygen -q -t #{type} -b #{bits} -N '' -f #{privkey}")

      [privkey, pubkey].each do |v|
        File.chmod(0400, v)
      end

      ok
    end
  end
end
