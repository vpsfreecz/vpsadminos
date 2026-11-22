module OsCtl::Oomd
  class ContainerScore
    attr_reader :pool, :id, :first_hit, :last_hit, :restart_hits, :stop_hits

    def initialize(pool, id)
      @pool = pool
      @id = id
      @restart_hits = 0
      @stop_hits = 0
    end

    def hit(restart: true, stop: true)
      @restart_hits += 1 if restart
      @stop_hits += 1 if stop
      @first_hit ||= Time.now
      @last_hit = Time.now
    end

    def miss(restart: true, stop: true)
      @restart_hits -= 1 if restart
      @restart_hits = 0 if @restart_hits < 0

      @stop_hits -= 1 if stop
      @stop_hits = 0 if @stop_hits < 0
    end

    def reset_restart_hits
      @restart_hits = 0
    end

    def reset_stop_hits
      @stop_hits = 0
    end
  end
end
