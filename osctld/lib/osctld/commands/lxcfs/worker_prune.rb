require 'osctld/commands/base'

module OsCtld
  class Commands::Lxcfs::WorkerPrune < Commands::Base
    handle :lxcfs_worker_prune

    def execute
      Lxcfs::Scheduler.prune_workers
      ok
    end
  end
end
