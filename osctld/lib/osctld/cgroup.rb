module OsCtld
  module CGroup
    FS = '/sys/fs/cgroup'

    def self.real_subsystem(subsys)
      return 'cpu,cpuacct' if %w(cpu cpuacct).include?(subsys)
      # TODO: net_cls, net_prio?
      subsys
    end
  end
end
