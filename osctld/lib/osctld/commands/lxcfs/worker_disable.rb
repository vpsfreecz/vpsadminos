require 'osctld/commands/base'

module OsCtld
  class Commands::Lxcfs::WorkerDisable < Commands::Base
    handle :lxcfs_worker_disable

    def execute
      Lxcfs::Scheduler.change_worker(opts[:worker]) do |worker|
        worker.disable
      end
      ok
    rescue Lxcfs::WorkerNotFound => e
      error(e.message)
    end
  end
end
