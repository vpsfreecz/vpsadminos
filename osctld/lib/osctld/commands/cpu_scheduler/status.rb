require 'osctld/commands/base'

module OsCtld
  class Commands::CpuScheduler::Status < Commands::Base
    handle :cpu_scheduler_status

    def execute
      ok(CpuScheduler.export_status)
    end
  end
end
