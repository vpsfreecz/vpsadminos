require 'digest'

module OsCtld
  module Utils::Receive
    def receive_pipeline_error(mbuffer_status, recv_status)
      failures = []
      failures << "mbuffer exited with #{mbuffer_status.exitstatus}" if mbuffer_status.exitstatus != 0
      failures << "zfs recv exited with #{recv_status.exitstatus}" if recv_status.exitstatus != 0
      "unable to receive stream, #{failures.join(' and ')}"
    end

    # rubocop:disable Naming/PredicateMethod
    def check_auth_pubkey(key_pool_name, key_name, ct, key_pubkey_hash: nil)
      key_pool = DB::Pools.find(key_pool_name)
      error!('key pool not found') unless key_pool

      used_key = ct.pool.send_receive_key_chain.get_key(ct.send_log.opts.key_name)

      if used_key.nil?
        log(:warn, "Used key #{ct.send_log.opts.key_name.inspect} not found in pool #{ct.pool.name}")
        return false
      end

      if key_pubkey_hash
        return Digest::SHA256.hexdigest(used_key.pubkey) == key_pubkey_hash
      end

      auth_key = key_pool.send_receive_key_chain.get_key(key_name)

      if auth_key.nil?
        log(:warn, "Authentication key #{key_name.inspect} not found in pool #{key_pool_name}")
        return false
      end

      auth_key.pubkey == used_key.pubkey
    end
    # rubocop:enable Naming/PredicateMethod
  end
end
