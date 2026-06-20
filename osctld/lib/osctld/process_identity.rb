require 'libosctl'

module OsCtld
  # Stable process identity with descriptors opened through one /proc entry.
  class ProcessIdentity
    attr_reader :pid, :pidfd, :proc_dir, :root_dir

    def self.open(pid, namespaces: [], root: false)
      identity = new(pid, namespaces:, root:)
      return identity unless block_given?

      begin
        yield identity
      ensure
        identity.close
      end
    end

    def initialize(pid, namespaces: [], root: false)
      @pid = Integer(pid)
      raise ArgumentError, 'pid has to be positive' if @pid <= 0

      @sys = OsCtl::Lib::Sys.new
      @pidfd = @sys.pidfd_open(@pid)
      @pidfd_stat = @pidfd.stat
      @namespaces = {}
      @proc_dir = nil
      @proc_dir_stat = nil
      @root_dir = nil

      @proc_dir = File.open(File.join('/proc', @pid.to_s))
      @proc_dir_stat = @proc_dir.stat

      unless @proc_dir_stat.directory? && alive?
        raise Errno::ESRCH, "process #{@pid} exited"
      end

      @root_dir = @sys.openat_io(proc_dir, 'root') if root

      namespaces.each do |name|
        ns_name = name.to_sym
        @namespaces[ns_name] = @sys.openat_io(proc_dir, File.join('ns', ns_name.to_s))
      end

      raise Errno::ESRCH, "process #{@pid} exited" unless alive?
    rescue StandardError
      close
      raise
    end

    def alive?
      fd = pidfd
      return false if fd.nil? || fd.closed?

      @sys.pidfd_alive?(fd)
    rescue SystemCallError, IOError
      false
    end

    # Duplicate every held descriptor without resolving the numeric PID again.
    # The copy can outlive this identity and remains bound to the same process,
    # proc entry, root, and namespaces.
    def duplicate(namespaces: [], root: false)
      copy = self.class.allocate
      copy.send(:initialize_duplicate, self, namespaces:, root:)
      copy
    end

    # Recheck that every retained descriptor still describes this live process
    # and that the process remains below the expected cgroup. This is used at
    # the last responsible moment before namespace or mount effects.
    def authenticate!(cgroup_path:)
      verify_process_descriptors!

      verify_root_context! if root_dir || @namespaces.any?
      unless in_cgroup_subtree?(cgroup_path)
        raise Errno::EXDEV, "process #{pid} left cgroup #{cgroup_path}"
      end

      verify_process_descriptors!

      self
    end

    def namespace(name)
      @namespaces.fetch(name.to_sym)
    end

    def cgroup_entries
      read_proc_file('cgroup').lines.map do |line|
        hierarchy, controllers, path = line.strip.split(':', 3)
        if hierarchy.nil? || controllers.nil? || path.nil? || path.empty?
          raise ArgumentError, "malformed cgroup entry #{line.inspect}"
        end

        {
          hierarchy:,
          controllers: controllers.split(','),
          path:
        }
      end
    end

    def cgroup_paths
      cgroup_entries.map { |entry| entry.fetch(:path) }
    end

    def in_cgroup_subtree?(path)
      prefix = File.absolute_path(path)

      entries = cgroup_entries
      return false if entries.empty?

      entries.all? do |entry|
        current = File.absolute_path(entry.fetch(:path))
        current == prefix || current.start_with?("#{prefix}/")
      end
    end

    def open_proc_file(name, mode = 'r', &)
      io = @sys.openat_io(proc_dir, name, flags: proc_open_flags(mode))
      return io unless block_given?

      begin
        yield io
      ensure
        io.close
      end
    end

    def read_proc_file(name)
      open_proc_file(name, &:read)
    end

    def files
      [pidfd, proc_dir, root_dir, *@namespaces.values].compact
    end

    def close
      @namespaces&.each_value { |io| close_io(io) }
      close_io(@root_dir)
      close_io(@proc_dir)
      close_io(@pidfd)
      @namespaces = {}
      @root_dir = nil
      @proc_dir = nil
      @proc_dir_stat = nil
      @pidfd = nil
      @pidfd_stat = nil
    end

    protected

    def initialize_duplicate(source, namespaces:, root:)
      @pid = source.pid
      @sys = source.instance_variable_get(:@sys)
      @pidfd = nil
      @pidfd_stat = source.instance_variable_get(:@pidfd_stat)
      @proc_dir = nil
      @proc_dir_stat = source.instance_variable_get(:@proc_dir_stat)
      @root_dir = nil
      @namespaces = {}

      raise Errno::ESRCH, "process #{@pid} exited" unless source.alive?

      @pidfd = source.pidfd.dup
      @proc_dir = source.proc_dir.dup
      @root_dir = source.root_dir ? source.root_dir.dup : nil
      @root_dir = @sys.openat_io(@proc_dir, 'root') if root && @root_dir.nil?
      source.instance_variable_get(:@namespaces).each do |name, io|
        @namespaces[name] = io.dup
      end
      namespaces.each do |name|
        ns_name = name.to_sym
        @namespaces[ns_name] ||=
          @sys.openat_io(@proc_dir, File.join('ns', ns_name.to_s))
      end

      raise Errno::ESRCH, "process #{@pid} exited" unless alive?
    rescue StandardError
      close
      raise
    end

    def verify_root_context!
      verify_process_descriptors!

      if root_dir
        current_root = @sys.openat_io(proc_dir, 'root')
        unless same_file?(current_root, root_dir)
          raise Errno::ESTALE, "process #{pid} changed root"
        end
      end

      current_namespaces = []
      @namespaces.each do |name, held|
        current = @sys.openat_io(proc_dir, File.join('ns', name.to_s))
        current_namespaces << current
        unless same_file?(current, held)
          display_name = name == :mnt ? 'mount' : name
          raise Errno::ESTALE, "process #{pid} changed #{display_name} namespace"
        end
      end

      verify_process_descriptors!
    ensure
      current_namespaces&.each(&:close)
      current_root&.close
    end

    def verify_process_descriptors!
      raise Errno::ESRCH, "process #{pid} exited" unless alive?

      unless same_file?(pidfd, @pidfd_stat)
        raise Errno::ESTALE, "process #{pid} pidfd was substituted"
      end

      unless same_file?(proc_dir, @proc_dir_stat)
        raise Errno::ESTALE, "process #{pid} proc descriptor was substituted"
      end

      raise Errno::ESRCH, "process #{pid} exited" unless alive?
    end

    def same_file?(left, right)
      left_stat = left.respond_to?(:stat) ? left.stat : left
      right_stat = right.respond_to?(:stat) ? right.stat : right

      left_stat.dev == right_stat.dev && left_stat.ino == right_stat.ino
    end

    def proc_open_flags(mode)
      case mode
      when 'r'
        File::RDONLY
      when 'w'
        File::WRONLY | File::TRUNC
      when 'a'
        File::WRONLY | File::APPEND
      when 'r+'
        File::RDWR
      when 'w+'
        File::RDWR | File::TRUNC
      when 'a+'
        File::RDWR | File::APPEND
      else
        Integer(mode)
      end
    end

    def close_io(io)
      io&.close unless io&.closed?
    end
  end
end
