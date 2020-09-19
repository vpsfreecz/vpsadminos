require 'osctld/commands/logged'

module OsCtld
  class Commands::Receive::AuthKeyAdd < Commands::Logged
    handle :receive_authkey_add

    def find
      if opts[:pool]
        pool = DB::Pools.find(opts[:pool])

      else
        pool = DB::Pools.get_or_default(nil)
      end

      pool || error!('pool not found')
    end

    def execute(pool)
      key_chain = pool.send_receive_key_chain

      if /^[a-zA-Z0-9_\-\:\.]{1,}$/ !~ opts[:name]
        error!('key name must consist only of a-z A-Z 0-9, _-:.')
      elsif key_chain.key_exist?(opts[:name])
        error!("key '#{opts[:name]}' already exists")
      elsif opts[:passphrase] && /^[a-zA-Z0-9_\-\:\.]{1,}$/ !~ opts[:passphrase]
        error!('passphrase must consist only of a-z A-Z 0-9, _-:.')
      end

      key_chain.authorize_key(
        opts[:name],
        opts[:public_key],
        from: opts[:from],
        ctid: opts[:ctid],
        passphrase: opts[:passphrase],
        single_use: opts[:single_use] ? true : false,
      )
      key_chain.save

      SendReceive.deploy

      ok
    end
  end
end
