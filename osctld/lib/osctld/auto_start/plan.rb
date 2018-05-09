module OsCtld
  class AutoStart::Plan
    include OsCtl::Lib::Utils::Log

    attr_reader :pool

    def initialize(pool)
      @pool = pool
      @plan = ExecutionPlan.new
    end

    def generate
      cts = DB::Containers.get.select { |ct| ct.pool == pool && ct.autostart }
      cts.sort! { |a, b| a.autostart <=> b.autostart }
      cts.each do |ct|
        plan << Item.new(ct.id, ct.autostart.priority, ct.autostart.delay)
      end
    end

    def start
      fail 'autostart already in progress' if plan.running?

      plan.on_start do
        log(
          :info, pool,
          "Auto-starting containers, #{pool.parallel_start} containers at a time"
        )
      end

      plan.on_done do
        log(:info, pool, 'Auto-starting containers finished')
      end

      plan.run(pool.parallel_start) do |it|
        ct = DB::Containers.find(it.id, pool)
        next if ct.nil? || ct.running?

        log(:info, ct, 'Auto-starting container')
        Commands::Container::Start.run(pool: ct.pool.name, id: ct.id)

        sleep(it.delay)
      end
    end

    def stop
      plan.stop
    end

    def running?
      plan.running?
    end

    def get_queue
      plan.queue
    end

    protected
    Item = Struct.new(:id, :priority, :delay)

    attr_reader :plan
  end
end
