require 'osctld/commands/base'

module OsCtld
  class Commands::Lxcfs::WorkerEnable < Commands::Base
    handle :lxcfs_worker_enable

    def execute
      Lxcfs::Scheduler.change_worker(opts[:worker]) do |worker|
        worker.enable
      end
      ok
    rescue Lxcfs::WorkerNotFound => e
      error(e.message)
    end
  end
end
