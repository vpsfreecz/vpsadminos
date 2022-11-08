require 'osctld/commands/base'

module OsCtld
  class Commands::Lxcfs::WorkerList < Commands::Base
    handle :lxcfs_worker_list

    def execute
      ok(Lxcfs::Scheduler.export_workers)
    end
  end
end
