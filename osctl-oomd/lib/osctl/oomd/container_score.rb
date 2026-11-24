module OsCtl::Oomd
  # Monotonic, coverage-bounded seconds. No score survives a controller restart.
  class ContainerScore
    attr_reader :pool, :id, :restart_qualified_seconds, :stop_qualified_seconds,
                :last_usable_ns, :anchor_ns, :qualification, :gate_token

    def initialize(pool, id)
      @pool = pool
      @id = id
      @restart_qualified_seconds = 0.0
      @stop_qualified_seconds = 0.0
    end

    def observe(now_ns:, qualification:, gate_token:, load_gate:, linked:, interval_ns:)
      delta = if linked && @anchor_ns && now_ns > @anchor_ns
                [now_ns - @anchor_ns, interval_ns].min / 1_000_000_000.0
              else
                0.0
              end
      if qualification.nil? || gate_token.nil?
        break_link
        return 0.0
      end

      @last_usable_ns = now_ns
      if !@qualification.nil? && delta > 0
        if qualification && @qualification && gate_token && continuous_gate?(gate_token)
          @restart_qualified_seconds += delta
        elsif qualification == false || gate_token == false
          @restart_qualified_seconds = [@restart_qualified_seconds - delta, 0.0].max
        end
        if load_gate == true && @load_gate == true
          if qualification && @qualification
            @stop_qualified_seconds += delta
          elsif qualification == false
            @stop_qualified_seconds = [@stop_qualified_seconds - delta, 0.0].max
          end
        end
      end
      @anchor_ns = now_ns
      @qualification = qualification
      @gate_token = gate_token
      @load_gate = load_gate
      delta
    end

    def expire(now_ns:, expiry_ns:)
      return unless @last_usable_ns && now_ns - @last_usable_ns >= expiry_ns

      reset_restart
    end

    def break_link
      @anchor_ns = @qualification = @gate_token = @load_gate = nil
    end

    def reset_restart
      @restart_qualified_seconds = 0.0
      @last_usable_ns = nil
      break_link
    end

    def reset_stop
      @stop_qualified_seconds = 0.0
    end

    protected

    def continuous_gate?(current)
      return false unless @gate_token
      return true if current[:load] && @gate_token[:load]

      current[:rtnl] && @gate_token[:rtnl] && current[:rtnl] == @gate_token[:rtnl]
    end
  end
end
