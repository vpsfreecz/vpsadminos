require 'libosctl'

module OsCtld
  class AutoStart::Plan
    include OsCtl::Lib::Utils::Log

    attr_reader :pool

    def initialize(pool)
      @pool = pool
      @plan = ContinuousExecutor.new(pool.parallel_start)
    end

    def start
      log(
        :info, pool,
        "Auto-starting containers, #{pool.parallel_start} containers at a time"
      )

      cts = DB::Containers.get.select { |ct| ct.pool == pool && ct.autostart }

      plan << (cts.map do |ct|
        ContinuousExecutor::Command.new(
          id: ct.id,
          priority: ct.autostart.priority,
        ) do |cmd|
          cur_ct = DB::Containers.find(cmd.id, pool)
          next if cur_ct.nil? || cur_ct.running?

          log(:info, ct, 'Auto-starting container')
          Commands::Container::Start.run(pool: cur_ct.pool.name, id: cur_ct.id)

          sleep(cur_ct.autostart.delay)
        end
      end)
    end

    def clear
      plan.clear
    end

    def resize(new_size)
      plan.resize(new_size)
    end

    def stop
      plan.stop
    end

    def queue
      plan.queue
    end

    protected
    attr_reader :plan
  end
end
