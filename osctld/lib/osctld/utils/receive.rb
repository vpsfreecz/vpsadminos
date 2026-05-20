require 'digest'

module OsCtld
  module Utils::Receive
    def receive_pipeline_error(mbuffer_status, recv_status)
      failures = []
      failures << "mbuffer exited with #{mbuffer_status.exitstatus}" if mbuffer_status.exitstatus != 0
      failures << "zfs recv exited with #{recv_status.exitstatus}" if recv_status.exitstatus != 0
      "unable to receive stream, #{failures.join(' and ')}"
    end

    def check_auth_pubkey(_key_pool_name, _key_name, ct, key_pubkey_hash:)
      if key_pubkey_hash.nil?
        log(:warn, 'Authentication key public-key hash not provided')
        return false
      end

      used_key = ct.pool.send_receive_key_chain.get_key(ct.send_log.opts.key_name)

      if used_key.nil?
        log(:warn, "Used key #{ct.send_log.opts.key_name.inspect} not found in pool #{ct.pool.name}")
        return false
      end

      Digest::SHA256.hexdigest(used_key.pubkey) == key_pubkey_hash
    end
  end
end
