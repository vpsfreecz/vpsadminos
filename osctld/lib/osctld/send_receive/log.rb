module OsCtld
  # This class serves as a scratchpad for container send/receive
  #
  # Both the source and the destination nodes have an instance of this class
  # per container. This class determines whether the next step of the send
  # can proceed, stores names of snapshots created during the send and
  # other settings.
  class SendReceive::Log
    STATES = %i(stage base incremental cancel transfer cleanup)

    class Options
      def self.load(cfg)
        new(Hash[cfg.map { |k,v| [k.to_sym, v] }])
      end

      # @return [String]
      attr_reader :ctid

      # @return [Integer]
      attr_reader :port

      # @return [String]
      attr_reader :dst

      # @param opts [Hash]
      # @option opts [String] :ctid
      # @option opts [Integer] :port
      # @option opts [String] :dst
      def initialize(opts)
        @ctid = opts.delete(:ctid)
        @port = opts.delete(:port)
        @dst = opts.delete(:dst)

        unless opts.empty?
          raise ArgumentError, "unsupported options: #{opts.keys.join(', ')}"
        end
      end

      # @param opt [Symbol]
      def [](opt)
        instance_variable_get(:"@#{opt}")
      end

      def dump
        {
          'ctid' => ctid,
          'port' => port,
          'dst' => dst,
        }
      end
    end

    attr_reader :role, :state, :snapshots, :opts

    def self.load(cfg)
      new(
        role: cfg['role'].to_sym,
        state: cfg['state'].to_sym,
        snapshots: cfg['snapshots'],
        opts: Options.load(cfg['opts']),
      )
    end

    # @param opts [Hash] options
    # @option opts [Symbol] role `:source`, `:destination`
    # @option opts [Symbol] state
    # @option opts [Array<String>] snapshots
    # @option opts [Options, Hash] opts
    def initialize(opts)
      @role = opts[:role]
      @state = opts[:state] || :stage
      @snapshots = opts[:snapshots] || []
      @opts = opts.is_a?(Options) ? opts : Options.new(opts[:opts] || {})
    end

    def dump
      {
        'role' => role.to_s,
        'state' => state.to_s,
        'snapshots' => snapshots,
        'opts' => opts.dump,
      }
    end

    def can_continue?(next_state)
      syncs = %i(base incremental)
      return false if state == :cancel

      next_i = STATES.index(next_state)
      return false unless next_i

      return true if syncs.include?(state) && syncs.include?(next_state)

      cur_i = STATES.index(state)
      return false if next_i < cur_i
      return true if next_i > cur_i
      false
    end

    def state=(v)
      fail "invalid state '#{v}'" unless STATES.include?(v)
      @state = v
    end
  end
end
