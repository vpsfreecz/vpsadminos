require 'osctld/commands/base'

module OsCtld
  class Commands::CpuScheduler::PackageList < Commands::Base
    handle :cpu_scheduler_package_list

    def execute
      ok(CpuScheduler.export_packages)
    end
  end
end
