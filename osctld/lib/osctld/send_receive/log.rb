module OsCtld
  # This class serves as a scratchpad for container send/receive
  #
  # Both the source and the destination nodes have an instance of this class
  # per container. This class determines whether the next step of the send
  # can proceed, stores names of snapshots created during the send and
  # other settings.
  class SendReceive::Log
    STATES = %i(stage base incremental transfer cleanup)

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

      # @param cloned [Boolean]
      # @return [Boolean]
      attr_accessor :cloned

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

        unless opts.empty?
          raise ArgumentError, "unsupported options: #{opts.keys.join(', ')}"
        end
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
      @opts = opts[:opts].is_a?(Options) ? opts[:opts] : Options.new(opts[:opts] || {})
    end

    def dump
      {
        'role' => role.to_s,
        'state' => state.to_s,
        'snapshots' => snapshots,
        'opts' => opts.dump,
      }
    end

    def can_send_continue?(next_state)
      cur_i = STATES.index(state)
      next_i = STATES.index(next_state)

      if !next_i
        false
      elsif state == :incremental && next_state == :incremental
        true
      else
        next_i > cur_i
      end
    end

    def can_send_cancel?(force)
      cancellable = %i(stage base incremental)
      cancellable << :transfer if force
      cancellable.include?(state)
    end

    def can_receive_continue?(next_state)
      syncs = %i(base incremental)
      cur_i = STATES.index(state)
      next_i = STATES.index(next_state)

      if !next_i
        false
      elsif syncs.include?(state) && syncs.include?(next_state)
        true
      else
        next_i > cur_i
      end
    end

    def can_receive_cancel?
      %i(stage base incremental).include?(state)
    end

    def state=(v)
      fail "invalid state '#{v}'" unless STATES.include?(v)
      @state = v
    end
  end
end
