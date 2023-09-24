require 'libosctl'
require 'osctld/lockable'

module OsCtld
  class SendReceive::KeyChain
    class Key
      def self.load(hash)
        new(
          hash['name'],
          hash['pubkey'],
          from: hash['from'],
          ctid: hash['ctid'],
          passphrase: hash['passphrase'],
          single_use: hash['single_use'],
          in_use: hash['in_use'],
        )
      end

      attr_reader :name, :pubkey, :from, :ctid, :passphrase, :single_use
      attr_accessor :in_use

      def initialize(name, pubkey, opts = {})
        @name = name
        @pubkey = pubkey
        @from = opts[:from] && opts[:from].split(',')
        @ctid = opts[:ctid]
        @passphrase = opts[:passphrase]
        @single_use = opts[:single_use]
        @in_use = opts[:in_use] || false
      end

      def single_use?
        single_use
      end

      def in_use?
        in_use
      end

      def dump
        {
          'name' => name,
          'pubkey' => pubkey,
          'from' => from && from.join(','),
          'ctid' => ctid,
          'passphrase' => passphrase,
          'single_use' => single_use,
          'in_use' => in_use,
        }
      end
    end

    include Lockable
    include OsCtl::Lib::Utils::Log

    def initialize(pool)
      init_lock
      @pool = pool
      @keys = []
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
        key_chain_path,
        desc: 'Keys authorized to send containers to this node',
        user: 0,
        group: 0,
        mode: 0400,
        optional: true
      )
    end

    def setup
      exclusively do
        keys.clear
        return unless File.exist?(key_chain_path)

        OsCtl::Lib::ConfigFile.load_yaml_file(key_chain_path).each do |v|
          keys << Key.load(v)
        end
      end
    end

    # @param io [IO]
    def deploy(io)
      inclusively do
        keys.each do |key|
          options = [
            "command=\"#{File.join(SendReceive::HOOK)} #{pool.name} #{key.name}\"",
            'restrict',
          ]

          io.puts("#{options.join(',')} #{key.pubkey}")
        end
      end
    end

    # @param name [String]
    def key_exist?(name)
      inclusively { !(keys.detect { |v| v.name == name }.nil?) }
    end

    # Find key by name
    # @param name [String]
    # @return [Key, nil]
    def get_key(name)
      inclusively do
        keys.detect { |v| v.name == name }
      end
    end

    # Find key by pubkey, client address/hostnames and passphrase
    # @param pubkey [String]
    # @param hosts [Array<String>]
    # @param passphrase [String]
    # @return [Key, nil]
    def find_key(pubkey, hosts, passphrase)
      inclusively do
        keys.detect do |k|
          next if k.pubkey != pubkey || k.passphrase != passphrase

          if k.from
            k.from.any? do |pattern|
              hosts.any? { |v| File.fnmatch?(pattern, v) }
            end
          else
            true
          end
        end
      end
    end

    # @param name [String]
    # @param pubkey [String]
    # @param opts [Hash]
    # @option opts [String] :from
    # @option opts [String] :ctid
    # @option opts [String] :passphrase
    # @option opts [Boolean] :single_use
    def authorize_key(name, pubkey, opts = {})
      exclusively do
        raise ArgumentError, 'key exists' if keys.detect { |v| v.name == name }
        keys << Key.new(name, pubkey, opts)
      end
    end

    # @param name [String]
    def revoke_key(name)
      exclusively do
        keys.delete_if { |v| v.name == name }
      end
    end

    # @param name [String]
    # @return [Boolean] true if the key has been updated
    def started_using_key(name)
      ret = false

      exclusively do
        key = keys.detect { |v| v.name == name }

        if key && key.single_use?
          ret = true
          key.in_use = true
          save
        end
      end

      ret
    end

    # @param name [String]
    # @return [Boolean] true if the key has been deleted
    def stopped_using_key(name)
      ret = false

      exclusively do
        i = keys.index { |v| v.name == name }

        if i && keys[i].single_use?
          ret = true
          keys.delete_at(i)
          save
        end
      end

      log(:info, "Removed single-use key #{name}") if ret

      ret
    end

    def export
      inclusively { keys.map(&:dump) }
    end

    def save
      exclusively do
        File.open(key_chain_path, 'w', 0400) do |f|
          f.write(OsCtl::Lib::ConfigFile.dump_yaml(keys.map(&:dump)))
        end
      end
    end

    def private_key_path
      File.join(pool.conf_path, 'send-receive', 'key')
    end

    def public_key_path
      "#{private_key_path}.pub"
    end

    def key_chain_path
      File.join(pool.conf_path, 'send-receive', 'keychain.yml')
    end

    def log_type
      "#{pool.name}:key-chain"
    end

    protected
    attr_reader :pool, :keys
  end
end
