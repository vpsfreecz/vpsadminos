require 'osctld/commands/logged'
require 'socket'

module OsCtld
  class Commands::Send::KeyGen < Commands::Logged
    handle :send_key_gen

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
      privkey = pool.send_receive_key_chain.private_key_path
      pubkey = pool.send_receive_key_chain.public_key_path

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

      args = [
        'ssh-keygen',
        '-q',
        '-t', type,
        '-b', bits.to_s,
        '-N', "''",
        '-C', "'#{pool.name}@#{Socket.gethostname}'",
        '-f', privkey,
      ]

      syscmd(args.join(' '))

      [privkey, pubkey].each do |v|
        File.chmod(0400, v)
      end

      ok
    end
  end
end
