require 'osctld/transfer'

module OsCtld
  class Transfer::Log
    STATES = %i[stage base incremental transfer cleanup].freeze

    attr_reader :role, :state, :snapshots, :opts
    attr_accessor :state_snapshot, :state_running

    def initialize(opts)
      @role = opts[:role]
      @state = opts[:state] || :stage
      @snapshots = opts[:snapshots] || []
      @state_snapshot = opts[:state_snapshot]
      @state_running = opts[:state_running]
      @opts = opts[:opts]
    end

    def can_continue?(next_state, sync_states: %i[base incremental])
      cur_i = STATES.index(state)
      next_i = STATES.index(next_state)

      if !cur_i || !next_i
        false
      elsif (state == :cleanup && next_state == :cleanup) ||
            (sync_states.include?(state) && sync_states.include?(next_state))
        true
      else
        next_i > cur_i
      end
    end

    def can_cancel?(force = false)
      cancellable = %i[stage base incremental]
      cancellable << :transfer if force
      cancellable.include?(state)
    end

    def state=(v)
      raise "invalid state '#{v}'" unless STATES.include?(v)

      @state = v
    end
  end
end
