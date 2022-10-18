require 'osctld/commands/base'

module OsCtld
  class Commands::CpuScheduler::PackageEnable < Commands::Base
    handle :cpu_scheduler_package_enable

    def execute
      if CpuScheduler.enable_package(opts[:package])
        ok
      else
        error("package #{opts[:package].inspect} not found")
      end
    end
  end
end
