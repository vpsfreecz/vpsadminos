require 'osctld/commands/base'

module OsCtld
  class Commands::CpuScheduler::Upkeep < Commands::Base
    handle :cpu_scheduler_upkeep

    def execute
      CpuScheduler.upkeep
      ok
    end
  end
end
