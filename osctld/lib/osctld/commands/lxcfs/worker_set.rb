require 'osctld/commands/base'

module OsCtld
  class Commands::Lxcfs::WorkerSet < Commands::Base
    handle :lxcfs_worker_set

    def execute
      Lxcfs::Scheduler.change_worker(opts[:worker]) do |worker|
        worker.max_size = opts[:max_size].to_i
      end
      ok
    rescue Lxcfs::WorkerNotFound => e
      error(e.message)
    end
  end
end
