require 'libosctl'
require 'etc'

module OsCtld
  class AutoStop::Plan
    include OsCtl::Lib::Utils::Log

    attr_reader :pool

    def initialize(pool)
      @pool = pool
      @plan = ContinuousExecutor.new(pool.parallel_stop)
      @stop = false
      @nproc = Etc.nprocessors
    end

    # Stop all containers on pool
    #
    # It is assumed that manipulation lock is held on all containers on the pool.
    #
    # @param client_handler [Generic::ClientHandler, nil]
    def start(client_handler: nil)
      @stop = false

      log(
        :info, pool,
        "Auto-stopping containers, #{pool.parallel_start} containers at a time"
      )

      # Sort containers by reversed autostart priority -- containers with
      # the lowest priority are stopped first
      cts = DB::Containers.get.select { |ct| ct.pool == pool }
      cts.sort! do |a, b|
        if a.autostart && b.autostart
          a.autostart <=> b.autostart

        elsif a.autostart
          -1

        elsif b.autostart
          1

        else
          0
        end
      end
      cts.reverse!

      # Progress counters
      total = cts.count
      done = 0
      mutex = Mutex.new

      # Stop the containers
      cmds = cts.map do |ct|
        ContinuousExecutor::Command.new(id: ct.id, priority: 0) do |cmd|
          if client_handler
            mutex.synchronize do
              done += 1
              client_handler.send_update(
                "[#{done}/#{total}] "+
                (ct.ephemeral? ? 'Deleting ephemeral container' : 'Stopping container')+
                " #{ct.ident}"
              )
            end
          end

          log(:info, ct, 'Auto-stopping container')
          do_stop_ct(ct)
        end
      end

      plan << cmds
    end

    def clear
      plan.clear
    end

    def resize(new_size)
      plan.resize(new_size)
    end

    def wait
      plan.wait_until_empty
    end

    def stop
      @stop = true
      plan.stop
    end

    def queue
      plan.queue
    end

    protected
    attr_reader :plan

    def do_stop_ct(ct)
      if ct.ephemeral?
        Commands::Container::Delete.run(
          pool: pool.name,
          id: ct.id,
          force: true,
          progress: false,
          manipulation_lock: 'ignore',
        )
      else
        Commands::Container::Stop.run(
          pool: pool.name,
          id: ct.id,
          progress: false,
          manipulation_lock: 'ignore',
        )

        pool.autostart_plan.clear_ct(ct)
      end
    end

    def stop?
      @stop
    end
  end
end
