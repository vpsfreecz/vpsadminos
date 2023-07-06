require 'libosctl'

module OsCtld
  module CGroup
    include OsCtl::Lib::Utils::Log

    FS = '/sys/fs/cgroup'

    ROOT_GROUP = 'osctl'

    DELEGATE_FILES = File.read('/sys/kernel/cgroup/delegate').strip.split

    MUTEX = Mutex.new

    def self.init
      begin
        @version = File.read(RunState::CGROUP_VERSION).strip.to_i
      rescue Errno::ENOENT
        @version = 1
      end

      @version = 1 if ![1, 2].include?(@version)

      @subsystems =
        if @version == 1
          Dir.entries(FS) - ['.', '..']
        else
          ['']
        end
    end

    # @return [1, 2] cgroup hierarchy version
    def self.version
      @version
    end

    def self.v1?
      @version == 1
    end

    def self.v2?
      @version == 2
    end

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
      @subsystems
    end

    # @return [Hash<Symbol, String>]
    def self.subsystem_paths
      Hash[%i(cpu cpuacct memory blkio pids).map do |subsys|
        [subsys, abs_cgroup_path(real_subsystem(subsys.to_s))]
      end]
    end

    # Return an absolute path to a cgroup
    # @param subsys [String] subsystem
    # @param path [String]
    # @return [String]
    def self.abs_cgroup_path(subsys, *path)
      if v1?
        File.join(FS, real_subsystem(subsys), *path)
      else
        File.join(FS, *path)
      end
    end

    # Check if cgroup exists
    # @param subsys [String] subsystem
    # @param path [String]
    # @return [Boolean]
    def self.abs_cgroup_path_exist?(subsys, *path)
      exist?(abs_cgroup_path(subsys, *path))
    end

    # Check if cgroup at path exists
    # @param abs_path [String] absolute cgroup path, including `/sys/fs/cgroup`
    # @return [Boolean]
    def self.exist?(abs_path)
      Dir.exist?(abs_path) && File.exist?(File.join(abs_path, 'cgroup.procs'))
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
    # @param leaf [Boolean] do not delegate controllers to the last cgroup
    # @param pid [Integer, nil] pid to attach, default to the current process
    # @return [Boolean] `true` if the last component was created, `false` if it
    #                   already existed
    def self.mkpath(type, path, chown: nil, attach: false, leaf: true, pid: nil)
      base = abs_cgroup_path(type)
      tmp = []
      created = false

      path.each_with_index do |name, i|
        tmp << name
        cgroup = File.join(base, *tmp)

        created = create(
          cgroup,
          delegate: i+1 < path.length || (!leaf && !attach),
          type: type,
          base: base,
        )
      end

      if chown
        cgroup = File.join(base, *path)

        File.chown(chown, chown, cgroup)
        File.chown(chown, chown, File.join(cgroup, 'cgroup.procs'))

        if v2? || type == 'unified'
          DELEGATE_FILES.each do |f|
            begin
              File.chown(chown, chown, File.join(cgroup, f))
            rescue Errno::ENOENT
            end
          end
        end
      end

      self.attach_to(type, path, pid: pid) if attach

      created
    end

    # Create cgroup path in all subsystems, see {self.mkpath}
    # @param path [Array<String>] paths to create
    # @param chown [Integer] chown the last group to `chown`:`chown`
    # @param attach [Boolean] attach the current process to the last group
    # @param leaf [Boolean] do not delegate controllers to the last cgroup
    # @param pid [Integer, nil] pid to attach, default to the current process
    def self.mkpath_all(path, chown: nil, attach: false, leaf: true, pid: nil)
      subsystems.each do |subsys|
        mkpath(subsys, path, chown: chown, attach: attach, pid: pid)
      end
    end

    # Create cgroup
    # @param cgroup [String] absolute cgroup path
    # @param delegate [Boolean] delegate controllers on cgroupv2
    # @param type [String] subsystem
    # @param base [String] absolute path to subsystem root
    # @return [Boolean] true if created, false if already existed
    def self.create(cgroup, delegate:, type:, base:)
      created = false

      sync do
        begin
          Dir.mkdir(cgroup)
          created = true
        rescue Errno::EEXIST
          created = false
        end

        if created && v2? && delegate
          CGroup.delegate_available_controllers(cgroup)
        end

        init_cgroup(type, base, cgroup) if created
      end

      created
    end

    # Attach process to a cgroup
    # @param type [String] subsystem
    # @param path [Array<String>] paths to create
    # @param pid [Integer, nil] pid to attach, default to the current process
    def self.attach_to(type, path, pid: nil)
      cgroup = File.join(abs_cgroup_path(type), *path)

      attached = false
      attach_pid = pid || Process.pid

      ['cgroup.procs', 'tasks'].each do |tasks|
        begin
          File.open(File.join(cgroup, tasks), 'w') do |f|
            f.puts(attach_pid)
          end
        rescue Errno::ENOENT
          next
        end

        attached = true
        break
      end

      unless attached
        fail "unable to attach pid #{attach_pid} to cgroup #{cgroup.inspect}"
      end

      nil
    end

    # Attach process to a cgroup in all subsystems
    # @param path [Array<String>] paths to create
    # @param pid [Integer, nil] pid to attach, default to the current process
    def self.attach_to_all(path, pid: nil)
      subsystems.each do |subsys|
        attach_to(subsys, path, pid: pid)
      end
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
        if v1?
          inherit_param(base, cgroup, 'cpuset.cpus')
          inherit_param(base, cgroup, 'cpuset.mems')
          set_param(File.join(cgroup, 'cgroup.clone_children'), ['1'])
        end
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

    # Enable all available controllers on cgroup
    # @param cgroup [String] absolute path of the cgroup
    def self.delegate_available_controllers(cgroup)
      cmd = available_controllers(cgroup).map do |controller|
        "+#{controller}"
      end.join(' ')

      File.write(File.join(cgroup, 'cgroup.subtree_control'), cmd)
    end

    # @param cgroup [String] absolute path of the cgroup
    # @return [Array<String>]
    def self.available_controllers(cgroup)
      File.read(File.join(cgroup, 'cgroup.controllers')).strip.split
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
      abs_path = abs_cgroup_path(subsystem, path)

      # Remove subdirectories recursively
      Dir.entries(abs_path).each do |dir|
        next if dir == '.' || dir == '..'
        next unless Dir.exist?(File.join(abs_path, dir))

        rmpath(subsystem, File.join(path, dir))
      end

      # Remove directory
      Dir.rmdir(abs_path)

      if CGroup.v2?
        # Remove pinned links for the cgroup
        Devices::V2::BpfProgramCache.prune_cgroup_links(abs_path)
      end

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
      abs_path = abs_cgroup_path('freezer', path)

      if v1?
        state = File.join(abs_path, 'freezer.state')

        begin
          File.open(state, 'w') { |f| f.write('FROZEN') }
        rescue SystemCallError => e
          log(:warn, "Unable to freeze #{abs_path}: #{e.message} (#{e.class})")
        end

      else
        state = File.join(abs_path, 'cgroup.freeze')

        begin
          File.open(state, 'w') { |f| f.write('1') }
        rescue SystemCallError => e
          log(:warn, "Unable to freeze #{abs_path}: #{e.message} (#{e.class})")
        end
      end
    end

    # Thaw all frozen cgroups under path
    # @param path [String]
    def self.thaw_tree(path)
      abs_path = abs_cgroup_path('freezer', path)

      Dir.entries(abs_path).each do |dir|
        next if dir == '.' || dir == '..'
        next unless Dir.exist?(File.join(abs_path, dir))

        thaw_tree(File.join(path, dir))
      end

      if v1?
        state = File.join(abs_path, 'freezer.state')

        begin
          if %w(FREEZING FROZEN).include?(File.read(state).strip)
            log(:info, "Thawing #{abs_path}")
            File.open(state, 'w') { |f| f.write('THAWED') }
          end
        rescue SystemCallError => e
          log(:warn, "Unable to thaw #{abs_path}: #{e.message} (#{e.class})")
        end

      else
        state = File.join(abs_path, 'cgroup.freeze')

        begin
          if File.read(state).strip == '1'
            log(:info, "Thawing #{abs_path}")
            File.open(state, 'w') { |f| f.write('0') }
          end
        rescue SystemCallError => e
          log(:warn, "Unable to thaw #{abs_path}: #{e.message} (#{e.class})")
        end
      end
    end

    def self.sync(&block)
      if MUTEX.owned?
        block.call
      else
        MUTEX.synchronize(&block)
      end
    end
  end
end
