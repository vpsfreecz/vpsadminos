require 'libosctl'

module OsCtld
  module CGroup
    include OsCtl::Lib::Utils::Log

    FS = '/sys/fs/cgroup'

    # Convert a single subsystem name to the mountpoint name, because some
    # CGroup subsystems are mounted in a shared mountpoint.
    def self.real_subsystem(subsys)
      return 'cpu,cpuacct' if %w(cpu cpuacct).include?(subsys)
      return 'net_cls,net_prio' if %w(net_cls net_prio).include?(subsys)
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
    # @return [Boolean] `true` if the last component was created, `false` if it
    #                   already existed
    def self.mkpath(type, path, chown: nil, attach: false)
      base = File.join(FS, type)
      tmp = []
      created = false

      path.each do |name|
        tmp << name
        cgroup = File.join(base, *tmp)

        next if Dir.exist?(cgroup)

        # Prevent an error if multiple processes attempt to create this cgroup
        # at a time
        begin
          Dir.mkdir(cgroup)
          created = true

        rescue Errno::EEXIST
          created = false
          next
        end

        init_cgroup(type, base, cgroup)
      end

      cgroup = File.join(base, *path)

      if chown
        File.chown(chown, chown, cgroup)
        File.chown(chown, chown, File.join(cgroup, 'cgroup.procs'))

        if type == 'unified'
          %w(cgroup.threads cgroup.subtree_control).each do |f|
            File.chown(chown, chown, File.join(cgroup, f))
          end
        end
      end

      if attach
        ['tasks', 'cgroup.procs'].each do |tasks|
          tasks_path = File.join(cgroup, tasks)
          next unless File.exist?(tasks_path)

          File.open(tasks_path, 'a') do |f|
            f.write("#{Process.pid}\n")
          end
        end
      end

      created
    end

    # Initialize cgroup after it was created.
    #
    # This is used to ensure that `cpuset` cgroups have parameters `cpuset.cpus`
    # and `cpuset.mems` set.
    #
    # @param type [String] cgroup subsystem
    # @param base [String] absolute path to the root cgroup
    # @param cgroup [String] absolute path of the created cgroup
    def self.init_cgroup(type, base, cgroup)
      case type
      when 'cpuset'
        inherit_param(base, cgroup, 'cpuset.cpus')
        inherit_param(base, cgroup, 'cpuset.mems')
        set_param(File.join(cgroup, 'cgroup.clone_children'), ['1'])
      end
    end

    # Inherit cgroup parameter from the parent cgroup
    #
    # The parameter is considered to be set if it isn't empty. If the parent
    # cgroup does not have the parameter set, it is inherited from its own
    # parent and so on, all the way to the root cgroup defined by `base`.
    # All parents will inherit the parameter as well.
    #
    # @param base [String] absolute path to the root cgroup
    # @param cgroup [String] absolute path of the created cgroup
    # @param param [String] parameter name
    def self.inherit_param(base, cgroup, param)
      v = File.read(File.join(cgroup, param)).strip
      return v unless v.empty?
      fail "parameter #{param} not set in root cgroup #{base}" if base == cgroup

      v = inherit_param(base, File.dirname(cgroup), param)
      set_param(File.join(cgroup, param), [v])
      v
    end

    # @return [Boolean]
    def self.set_param(path, value)
      raise CGroupFileNotFound.new(path, value) unless File.exist?(path)
      ret = true

      value.each do |v|
        log(:info, :cgroup, "Set #{path}=#{v}")

        begin
          File.write(path, v.to_s)

        rescue => e
          log(
            :warn,
            :cgroup,
            "Unable to set #{path}=#{v}: #{e.message}"
          )
          ret = false
        end
      end

      ret
    end

    # Remove cgroup path
    # @param subsystem [String]
    # @param path [String] path to remove, relative to the subsystem
    def self.rmpath(subsystem, path)
      abs_path = File.join(FS, subsystem, path)

      # Remove subdirectories recursively
      Dir.entries(abs_path).each do |dir|
        next if dir == '.' || dir == '..'
        next unless Dir.exist?(File.join(abs_path, dir))

        rmpath(subsystem, File.join(path, dir))
      end

      # Remove directory
      Dir.rmdir(abs_path)

    rescue Errno::ENOENT
      # pass
    end

    # Remove cgroup path in all subsystems
    # @param path [String] path to remove, relative to subsystem
    def self.rmpath_all(path)
      subsystems.each { |subsys| rmpath(subsys, path) }
    end

    # Freeze cgroup at path
    # @param path [String]
    def self.freeze_tree(path)
      abs_path = File.join(FS, real_subsystem('freezer'), path)
      state = File.join(abs_path, 'freezer.state')

      begin
        File.open(state, 'w') { |f| f.write('FROZEN') }
      rescue SystemCallError => e
        log(:warn, "Unable to freeze #{abs_path}: #{e.message} (#{e.class})")
      end
    end

    # Thaw all frozen cgroups under path
    # @param path [String]
    def self.thaw_tree(path)
      abs_path = File.join(FS, real_subsystem('freezer'), path)

      Dir.entries(abs_path).each do |dir|
        next if dir == '.' || dir == '..'
        next unless Dir.exist?(File.join(abs_path, dir))

        thaw_tree(File.join(path, dir))
      end

      state = File.join(abs_path, 'freezer.state')

      begin
        if %w(FREEZING FROZEN).include?(File.read(state).strip)
          log(:info, "Thawing #{abs_path}")
          File.open(state, 'w') { |f| f.write('THAWED') }
        end
      rescue SystemCallError => e
        log(:warn, "Unable to thaw #{abs_path}: #{e.message} (#{e.class})")
      end
    end
  end
end
