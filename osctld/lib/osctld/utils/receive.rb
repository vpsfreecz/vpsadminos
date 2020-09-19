module OsCtld
  module Utils::Receive
    def check_auth_pubkey(key_pool_name, key_name, ct)
      key_pool = DB::Pools.find(key_pool_name)
      error!('key pool not found') unless key_pool

      auth_key = key_pool.send_receive_key_chain.get_key(key_name)
      used_key = ct.pool.send_receive_key_chain.get_key(ct.send_log.opts.key_name)

      auth_key.pubkey == used_key.pubkey
    end
  end
end
