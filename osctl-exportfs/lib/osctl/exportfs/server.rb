module OsCtl::ExportFS
  # Represents a NFS server
  class Server
    # @return [String]
    attr_reader :name

    # Server root directory
    # @return [String]
    attr_reader :dir

    # Directory mounted to /var/lib/nfs
    # @return [String]
    attr_reader :nfs_state

    # Directory used to propagate mounts from the host to the server's namespace
    # @return [String]
    attr_reader :shared_dir

    # Root directory with runit configuration, which is mounted to /etc/runit
    # @return [String]
    attr_reader :runit_dir

    # Directory that the server's runsvdir is run with
    # @return [String]
    attr_reader :runit_runsvdir

    # Server service running on the host
    # @return [String]
    attr_reader :runsv_dir

    # Path to file with export database
    # @return [String]
    attr_reader :exports_db

    # Path to file mounted to /etc/exportfs
    # @return [String]
    attr_reader :exports_file

    # Path to file with the PID of the server's init process
    # @return [String]
    attr_reader :pid_file

    # @param name [String]
    def initialize(name)
      @name = name
      leave_ns
    end

    def running?
      File.stat(pid_file).size > 0
    rescue Errno::ENOENT
      false
    end

    # @return [Integer]
    def read_pid
      File.read(pid_file).strip.to_i
    end

    # Reconfigure the object to return paths relative to the server's mount
    # namespace
    def enter_ns
      @dir = File.join(RunState::CURRENT_SERVER)
      set_paths
    end

    # Reconfigure the object to return paths relative to the host's mount
    # namespace
    def leave_ns
      @dir = File.join(RunState::SERVERS, name)
      set_paths
    end

    protected
    def set_paths
      @nfs_state = File.join(@dir, 'state')
      @shared_dir = File.join(@dir, 'shared')
      @runit_dir = File.join(@dir, 'runit')
      @runit_runsvdir = File.join(@runit_dir, 'runsvdir')
      @runsv_dir = File.join(@dir, 'runsv')
      @exports_db = File.join(@dir, 'exports.yml')
      @exports_file = File.join(@dir, 'exports.exportfs')
      @pid_file = File.join(@dir, 'pid')
    end
  end
end
