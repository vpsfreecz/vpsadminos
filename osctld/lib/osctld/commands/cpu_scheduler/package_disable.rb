require 'osctld/commands/base'

module OsCtld
  class Commands::CpuScheduler::PackageDisable < Commands::Base
    handle :cpu_scheduler_package_disable

    def execute
      if CpuScheduler.disable_package(opts[:package])
        ok
      else
        error("package #{opts[:package].inspect} not found")
      end
    end
  end
end
