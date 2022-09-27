require 'libosctl'
require 'etc'

module OsCtld
  class AutoStart::Plan
    include OsCtl::Lib::Utils::Log

    attr_reader :pool

    def initialize(pool)
      @pool = pool
      @plan = ContinuousExecutor.new(pool.parallel_start)
      @state = AutoStart::State.load(pool)
      @stop = false
      @nproc = Etc.nprocessors
    end

    def assets(add)
      state.assets(add)
    end

    def start(force: false)
      @stop = false

      log(
        :info, pool,
        "Auto-starting containers, #{pool.parallel_start} containers at a time"
      )

      cts = DB::Containers.get.select do |ct|
        ct.pool == pool && ct.autostart && ct.can_start? && (force || !state.is_started?(ct))
      end

      plan << (cts.map do |ct|
        ContinuousExecutor::Command.new(
          id: ct.id,
          priority: ct.autostart.priority,
        ) do |cmd|
          cur_ct = DB::Containers.find(cmd.id, pool)
          if cur_ct.nil? || !ct.can_start?
            next
          elsif cur_ct.running?
            state.set_started(cur_ct)
            next
          end

          log(:info, ct, 'Auto-starting container')
          do_try_start_ct(cur_ct)
        end
      end)
    end

    def enqueue(ct, priority: 10, start_opts: {})
      plan << (
        ContinuousExecutor::Command.new(id: ct.id, priority: priority) do |cmd|
          cur_ct = DB::Containers.find(cmd.id, pool)
          next if cur_ct.nil? || cur_ct.running?

          log(:info, ct, 'Starting enqueued container')
          do_try_start_ct(cur_ct, start_opts: start_opts.merge(queue: false))
        end
      )
    end

    def start_ct(ct, priority: 10, start_opts: {}, client_handler: nil)
      plan.execute(
        ContinuousExecutor::Command.new(id: ct.id, priority: priority) do |cmd|
          cur_ct = DB::Containers.find(cmd.id, pool)
          next if cur_ct.nil? || cur_ct.running?

          log(:info, ct, 'Starting enqueued container')
          Commands::Container::Start.run(
            **start_opts.merge(
              pool: cur_ct.pool.name,
              id: cur_ct.id,
              queue: false,
              internal: {handler: client_handler},
            ),
          )
        end,
        timeout: start_opts ? (start_opts[:wait] || 60) : nil,
      )
    end

    def stop_ct(ct)
      plan.remove(ct.id)
    end

    def clear_ct(ct)
      state.clear(ct)
    end

    def clear
      plan.clear
    end

    def resize(new_size)
      plan.resize(new_size)
    end

    def stop
      @stop = true
      plan.stop
    end

    def queue
      plan.queue
    end

    protected
    attr_reader :plan, :state

    def do_try_start_ct(ct, attempts: 5, cooldown: 5, start_opts: {})
      attempts.times do |i|
        return if stop?

        ret = Commands::Container::Start.run(**start_opts.merge(
          pool: ct.pool.name,
          id: ct.id,
        ))

        if ret[:status]
          state.set_started(ct)
          return if stop?

          if delay_after_start?
            log(:info, ct, "Autostart delay for #{ct.autostart.delay} seconds")
            sleep(ct.autostart.delay)
          else
            log(:info, ct, 'Skipping autostart delay thanks to low system load average')
          end

          return
        end

        if i+1 == attempts
          log(:warn, ct, 'All attempts to start the container have failed')
          return
        end

        if stop?
          log(:warn, ct, "Unable to start the container, giving up to stop")
          return
        else
          pause = cooldown + i * cooldown
          log(:warn, ct, "Unable to start the container, retrying in #{pause} seconds")
          sleep(pause)
        end
      end
    end

    def delay_after_start?
      lavg = OsCtl::Lib::LoadAvg.new
      lavg.avg[1] >= @nproc
    end

    def stop?
      @stop
    end
  end
end
