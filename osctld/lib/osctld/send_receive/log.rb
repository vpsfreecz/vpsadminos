require 'osctld/send_receive'
require 'osctld/transfer/log'

module OsCtld
  # This class serves as a scratchpad for container send/receive
  #
  # Both the source and the destination nodes have an instance of this class
  # per container. This class determines whether the next step of the send
  # can proceed, stores names of snapshots created during the send and
  # other settings.
  class SendReceive::Log < Transfer::Log
    class Options
      def self.load(cfg)
        new(cfg.transform_keys(&:to_sym))
      end

      # @return [String]
      attr_reader :ctid

      # @return [Integer]
      attr_reader :port

      # @return [String]
      attr_reader :dst

      # @return [Boolean]
      attr_accessor :cloned

      # @return [String]
      attr_reader :key_name

      # @return [Boolean]
      attr_reader :snapshots

      # @return [String, nil]
      attr_reader :from_snapshot

      # @return [Boolean]
      attr_reader :preexisting_datasets

      # @return [Integer]
      attr_reader :protocol_version

      # @param opts [Hash]
      # @option opts [String] :ctid
      # @option opts [Integer] :port
      # @option opts [String] :dst
      # @option opts [Boolean, nil] :cloned
      def initialize(opts)
        @ctid = opts.delete(:ctid)
        @port = opts.delete(:port)
        @dst = opts.delete(:dst)
        @cloned = opts.delete(:cloned)
        @key_name = opts.delete(:key_name)
        @snapshots = opts.delete(:snapshots)
        @from_snapshot = opts.delete(:from_snapshot)
        @preexisting_datasets = opts.delete(:preexisting_datasets)
        @protocol_version = opts.delete(:protocol_version) || SendReceive::PROTOCOL_VERSION

        return if opts.empty?

        raise ArgumentError, "unsupported options: #{opts.keys.join(', ')}"
      end

      # @param opt [Symbol]
      def [](opt)
        instance_variable_get(:"@#{opt}")
      end

      def cloned?
        cloned ? true : false
      end

      def dump
        {
          'ctid' => ctid,
          'port' => port,
          'dst' => dst,
          'cloned' => cloned?,
          'key_name' => key_name,
          'snapshots' => snapshots,
          'from_snapshot' => from_snapshot,
          'preexisting_datasets' => preexisting_datasets,
          'protocol_version' => protocol_version
        }
      end
    end

    attr_reader :token

    def self.load(cfg)
      new(
        role: cfg['role'].to_sym,
        token: cfg['token'],
        state: cfg['state'].to_sym,
        snapshots: cfg['snapshots'],
        state_snapshot: cfg['state_snapshot'],
        state_running: cfg['state_running'],
        opts: Options.load(cfg['opts'])
      )
    end

    # @param opts [Hash] options
    # @option opts [Symbol] role `:source`, `:destination`
    # @option opts [String] token
    # @option opts [Symbol] state
    # @option opts [Array<String>] snapshots
    # @option opts [String, nil] state_snapshot
    # @option opts [Boolean, nil] state_running
    # @option opts [Options, Hash] opts
    def initialize(opts)
      @token = opts[:token]
      super(opts.merge(opts: opts[:opts].is_a?(Options) ? opts[:opts] : Options.new(opts[:opts] || {})))
    end

    def dump
      {
        'role' => role.to_s,
        'token' => token,
        'state' => state.to_s,
        'snapshots' => snapshots,
        'state_snapshot' => state_snapshot,
        'state_running' => state_running,
        'opts' => opts.dump
      }
    end

    def protocol_version
      opts.protocol_version
    end

    def can_send_continue?(next_state)
      can_continue?(next_state, sync_states: %i[incremental])
    end

    def can_send_cancel?(force)
      can_cancel?(force)
    end

    def can_receive_continue?(next_state)
      can_continue?(next_state, sync_states: %i[base incremental])
    end

    def can_receive_cancel?
      can_cancel?(false)
    end

    def close
      SendReceive::Tokens.free(token)
    end
  end
end
