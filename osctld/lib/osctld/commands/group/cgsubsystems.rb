require 'osctld/commands/base'

module OsCtld
  class Commands::Group::CGSubsystems < Commands::Base
    handle :group_cgsubsystems

    def execute
      if CGroup.v2?
        error!('command group_cgsubsystems is for cgroupv1, but v2 in use')
      end

      ret = {}

      %w(cpu cpuacct memory pids).each do |v|
        ret[v] = CGroup.abs_cgroup_path(CGroup.real_subsystem(v))
      end

      ok(ret)
    end
  end
end
