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
    # @param message [String]
    # @param client_handler [Generic::ClientHandler, nil]
    # @param progress_tracker [ProgressTracker]
    def start(message: nil, client_handler: nil, progress_tracker: nil)
      @stop = false
      progress_tracker ||= ProgressTracker.new

      log(
        :info,
        "Auto-stopping containers, #{pool.parallel_stop} containers at a time"
      )

      # Sort containers by reversed autostart priority -- containers with
      # the lowest priority are stopped first
      cts = DB::Containers.get.select { |ct| ct.pool == pool }

      log(:info, "#{cts.size} containers to stop")

      if CpuScheduler.use_sequential_start_stop?
        log(:info, 'Using sequential auto-stop')

        cts.sort! do |a, b|
          a_conf = a.run_conf
          b_conf = b.run_conf

          # rubocop:disable Lint/DuplicateBranch
          #
          # Stop running containers first
          if a_conf && !b_conf
            -1
          elsif !a_conf && b_conf
            1
          elsif !a_conf && !b_conf
            0

          # Stop containers with a CPU package first
          elsif a_conf.cpu_package && !b_conf.cpu_package
            -1
          elsif !a_conf.cpu_package && b_conf.cpu_package
            1
          elsif !a_conf.cpu_package && !b_conf.cpu_package
            0

          # Same CPU package, sort by autostart priority
          elsif a_conf.cpu_package == b_conf.cpu_package
            if a.autostart && b.autostart
              b.autostart <=> a.autostart
            elsif a.autostart
              1
            elsif b.autostart
              -1
            else
              0
            end

          # Sort by CPU package, higher package first
          else
            b_conf.cpu_package <=> a_conf.cpu_package
          end

          # rubocop:enable Lint/DuplicateBranch
        end
      else
        log(:info, 'Using priority auto-stop')

        cts.sort! do |a, b|
          if a.autostart && b.autostart
            b.autostart <=> a.autostart
          elsif a.autostart
            1
          elsif b.autostart
            -1
          else
            0
          end
        end
      end

      # Progress counters
      progress_tracker.add_total(cts.count)
      debug = Daemon.get.config.debug?

      # Stop the containers
      cmds = cts.each_with_index.map do |ct, i|
        if debug
          run_conf = ct.run_conf

          log(
            :debug,
            progress_tracker.progress_line(
              "#{ct.id} priority=#{ct.autostart ? ct.autostart.priority : '-'} cpu-package=#{run_conf ? run_conf.cpu_package : '-'}",
              increment_by: nil
            )
          )
        end

        ContinuousExecutor::Command.new(id: ct.id, priority: i) do |_cmd|
          if client_handler
            progress = progress_tracker.progress_line(
              (ct.ephemeral? ? 'Deleting ephemeral container' : 'Stopping container') +
              " #{ct.ident}"
            )

            client_handler.send_update(progress)
          end

          log(:info, ct, 'Auto-stopping container')
          do_stop_ct(ct, message:)
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

    def log_type
      "#{pool.name}:auto-stop"
    end

    protected

    attr_reader :plan

    def do_stop_ct(ct, message: nil)
      if ct.ephemeral?
        Commands::Container::Delete.run(
          pool: pool.name,
          id: ct.id,
          force: true,
          progress: false,
          manipulation_lock: 'ignore',
          message:
        )
      else
        Commands::Container::Stop.run(
          pool: pool.name,
          id: ct.id,
          progress: false,
          manipulation_lock: 'ignore',
          message:
        )

        pool.autostart_plan.clear_ct(ct)
      end
    end

    def stop?
      @stop
    end
  end
end
