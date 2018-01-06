module OsCtld
  module CGroup
    FS = '/sys/fs/cgroup'

    # Convert a single subsystem name to the mountpoint name, because some
    # CGroup subsystems are mounted in a single mountpoint.
    def self.real_subsystem(subsys)
      return 'cpu,cpuacct' if %w(cpu cpuacct).include?(subsys)
      # TODO: net_cls, net_prio?
      subsys
    end

    # Returns a list of mounted CGroup subsystems on the system
    # @return [Array<String>]
    def self.subsystems
      Dir.entries(FS) - ['.', '..']
    end

    # Create CGroup a path, optionally chowning the last CGroup or attaching
    # the current process into it.
    #
    # For example, `path` `['osctl', 'subgroup', 'subsubgroup']` will create
    # `osctl/subgroup/subsubgroup` in the chosen subsystem. If `chown` or
    # `attach` is set, it has an effect on the last group, i.e. `subsubgroup`,
    #
    # @param type [String] subsystem
    # @param path [Array<String>] paths to create
    # @param chown [Integer] chown the last group to `chown`:`chown`
    # @param attach [Boolean] attach the current process to the last group
    def self.mkpath(type, path, chown: nil, attach: false)
      base = File.join(FS, type)
      tmp = []

      path.each do |name|
        tmp << name
        cgroup = File.join(base, *tmp)

        next if Dir.exist?(cgroup)

        # Prevent an error if multiple processes attempt to create this cgroup
        # at a time
        begin
          Dir.mkdir(cgroup)

        rescue Errno::EEXIST
          next
        end
      end

      cgroup = File.join(base, *path)
      File.chown(chown, chown, cgroup) if chown

      if attach
        ['tasks', 'cgroup.procs'].each do |tasks|
          tasks_path = File.join(cgroup, tasks)
          next unless File.exist?(tasks_path)

          File.open(tasks_path, 'a') do |f|
            f.write("#{Process.pid}\n")
          end
        end
      end
    end
  end
end
