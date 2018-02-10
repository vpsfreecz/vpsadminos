module OsCtld
  # This class serves as a scratchpad for migrations
  #
  # Both the source and the destination nodes have an instance of this class
  # per container. This class determines whether the next step of the migration
  # can proceed, stores names of snapshots created during the migration and
  # other settings.
  class Migration::Log
    STATES = %i(stage base incremental cancel transfer cleanup)

    attr_reader :role, :state, :snapshots, :opts

    def self.load(cfg)
      new(
        role: cfg['role'].to_sym,
        state: cfg['state'].to_sym,
        snapshots: cfg['snapshots'],
        opts: Hash[cfg['opts'].map { |k,v| [k.to_sym, v] }],
      )
    end

    # @param opts [Hash] options
    # @option opts [Symbol] role `:source`, `:destination`
    # @option opts [Symbol] state
    # @option opts [Array<String>] snapshots
    # @option opts [Hash] opts
    def initialize(opts)
      @role = opts[:role]
      @state = opts[:state] || :stage
      @snapshots = opts[:snapshots] || []
      @opts = opts[:opts] || {}
    end

    def dump
      {
        'role' => role.to_s,
        'state' => state.to_s,
        'snapshots' => snapshots,
        'opts' => Hash[opts.map { |k,v| [k.to_s, v] }],
      }
    end

    def can_continue?(next_state)
      return false if state == :cancel

      next_i = STATES.index(next_state)
      return false unless next_i

      cur_i = STATES.index(state)
      return false if next_i < cur_i
      return true if next_i > cur_i

      # cur_i == next_i at this point, i.e. state == next_state
      # allow multiple base syncs -- one for each datasets
      # there can be multiple incrementals even for a single dataset
      return true if %i(base incremental).include?(state)
      false
    end

    def state=(v)
      fail "invalid state '#{v}'" unless STATES.include?(v)
      @state = v
    end
  end
end
