module OsCtld
  class SendReceive::KeyChain
    def initialize(pool)
      @pool = pool
    end

    def assets(add)
      add.file(
        private_key_path,
        desc: 'Identity private key',
        user: 0,
        group: 0,
        mode: 0400,
        optional: true
      )
      add.file(
        public_key_path,
        desc: 'Identity public key',
        user: 0,
        group: 0,
        mode: 0400,
        optional: true
      )
      add.file(
        authorized_keys_path,
        desc: 'Keys authorized to send containers to this node',
        user: 0,
        group: 0,
        mode: 0400,
        optional: true
      )
    end

    def setup
      deploy
    end

    def deploy
      return unless File.exist?(authorized_keys_path)

      options = [
        "command=\"#{File.join(SendReceive::HOOK)}\"",
        'restrict',
      ]

      # Generate new authorized_keys
      regenerate_existing_file(SendReceive::AUTHORIZED_KEYS) do |new, old|
        old.each_line { |line| new.write(line) }

        authorized_keys do |key|
          new.puts("#{options.join(',')} #{key}")
        end
      end
    end

    def authorized_keys
      path = authorized_keys_path

      if File.exist?(path)
        if block_given?
          File.open(path, 'r').each_line { |line| yield(line.strip) }
        else
          File.readlines(path).map(&:strip)
        end

      else
        []
      end
    end

    def authorize_key(pubkey)
      regenerate_file(authorized_keys_path, 0400) do |new, old|
        old.each_line { |line| new.write(line) } if old
        new.puts(pubkey)
      end
    end

    def revoke_key(index)
      return unless File.exist?(authorized_keys_path)

      regenerate_existing_file(authorized_keys_path) do |new, old|
        i = 0

        old.each_line do |line|
          new.write(line) if index != i
          i += 1
        end
      end
    end

    def replace_authorized_keys(pubkeys)
      regenerate_file(authorized_keys_path, 0400) do |new, old|
        pubkeys.each { |pubkey| new.puts(pubkey) }
      end
    end

    def private_key_path
      File.join(pool.conf_path, 'send-receive', 'key')
    end

    def public_key_path
      "#{private_key_path}.pub"
    end

    def authorized_keys_path
      File.join(pool.conf_path, 'send-receive', 'authorized_keys')
    end

    protected
    attr_reader :pool

    def regenerate_existing_file(path)
      replacement = "#{path}.new"
      stat = File.stat(path)

      File.open(replacement, 'w', stat.mode) do |new|
        File.open(path, 'r') do |old|
          yield(new, old)
        end
      end

      File.chown(stat.uid, stat.gid, replacement)
      File.rename(replacement, path)
    end

    def regenerate_file(path, mode)
      replacement = "#{path}.new"

      File.open(replacement, 'w', mode) do |new|
        if File.exist?(path)
          File.open(path, 'r') do |old|
            yield(new, old)
          end

        else
          yield(new, nil)
        end
      end

      File.rename(replacement, path)
    end
  end
end
