module OsCtld
  module Utils::Receive
    def check_auth_pubkey(key_pool_name, key_name, ct)
      key_pool = DB::Pools.find(key_pool_name)
      error!('key pool not found') unless key_pool

      auth_key = key_pool.send_receive_key_chain.get_key(key_name)

      if auth_key.nil?
        log(:warn, "Authentication key #{key_name.inspect} not found in pool #{key_pool_name}")
        return false
      end

      used_key = ct.pool.send_receive_key_chain.get_key(ct.send_log.opts.key_name)

      if used_key.nil?
        log(:warn, "Used key #{ct.send_log.opts.key_name.inspect} not found in pool #{ct.pool.name}")
        return false
      end

      auth_key.pubkey == used_key.pubkey
    end
  end
end
