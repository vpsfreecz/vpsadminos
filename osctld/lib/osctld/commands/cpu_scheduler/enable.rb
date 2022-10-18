require 'osctld/commands/base'

module OsCtld
  class Commands::CpuScheduler::Enable < Commands::Base
    handle :cpu_scheduler_enable

    def execute
      CpuScheduler.enable
      ok
    end
  end
end
