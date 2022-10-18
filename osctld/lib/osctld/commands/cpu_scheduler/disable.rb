require 'osctld/commands/base'

module OsCtld
  class Commands::CpuScheduler::Disable < Commands::Base
    handle :cpu_scheduler_disable

    def execute
      CpuScheduler.disable
      ok
    end
  end
end
