require 'fileutils'
require 'libosctl'

module OsCtld
  # Manage LXCFS instance using osctl-lxcfs runit service on the host
  class Lxcfs::Server
    RUNDIR_SERVERS = File.join(RunState::LXCFS_DIR, 'servers')
    RUNDIR_RUNSVDIR = File.join(RunState::LXCFS_DIR, 'runsvdir')
    RUNDIR_MOUNTROOT = File.join(RunState::LXCFS_DIR, 'mountpoint')

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    # @return [String]
    attr_reader :name

    # @return [String, nil]
    attr_reader :cpuset

    # @return [Boolean]
    attr_reader :loadavg

    # @return [Boolean]
    attr_reader :cfs

    # @return [String]
    attr_reader :mountroot

    # @return [String]
    attr_reader :mountpoint

    # @param name [String] LXCFS instance name, used for runit service
    # @param uid [Integer] user ID with access to the mountpoint
    # @param gid [Integer] group ID with access to the mountpoint
    # @param mode [Integer] mountpoint access mode
    # @param cpuset [String, nil] cpuset mask
    # @param loadavg [Boolean] enable load average tracking
    # @param cfs [Boolean] enable virtualized CPU usage view based on CFS quotas
    def initialize(name, uid: 0, gid: 0, mode: 0555, cpuset: nil, loadavg: true, cfs: true)
      @name = name
      @uid = uid
      @gid = gid
      @mode = mode
      @cpuset = cpuset
      @loadavg = loadavg
      @cfs = cfs
      @runsv_source = File.join(RUNDIR_SERVERS, name)
      @runsv_target = File.join(RUNDIR_RUNSVDIR, name)
      @runsv_run = File.join(runsv_source, 'run')
      @mountroot = File.join(RUNDIR_MOUNTROOT, name)
      @mountpoint = File.join(mountroot, 'mount')
      @cgroup_root = CGroup.abs_cgroup_path('cpuset', CGroup::ROOT_GROUP, 'lxcfs')
      @cgroup_dir = File.join(@cgroup_root, name)
    end

    def running?
      Dir.exist?(runsv_target)
    end

    def start
      create unless exist?

      log(:info, "Starting LXCFS")

      FileUtils.mkdir_p(mountroot)
      File.chown(uid, gid, mountroot)
      File.chmod(mode, mountroot)

      begin
        File.symlink(runsv_source, runsv_target)
      rescue Errno::EEXIST
      end
    end

    def restart
      log(:info, "Restarting LXCFS")
      sv_command('restart')
    end

    def stop
      log(:info, "Stopping LXCFS")
      sv_command('stop')
      File.unlink(runsv_target)
    end

    def destroy
      log(:info, "Destroying LXCFS")
      FileUtils.rm_rf(runsv_source, secure: true)

      begin
        Dir.rmdir(mountpoint)
      rescue Errno::ENOENT
        # pass
      rescue SystemCallError => e
        log(
          :fatal,
          "Unable to delete LXCFS mountpoint at #{mountpoint}: #{e.message} (#{e.class})"
        )
      end

      begin
        Dir.rmdir(mountroot)
      rescue Errno::ENOENT
        # pass
      rescue SystemCallError => e
        log(
          :fatal,
          "Unable to delete LXCFS mountroot at #{mountroot}: #{e.message} (#{e.class})"
        )
      end

      begin
        Dir.rmdir(cgroup_dir)
      rescue Errno::ENOENT
        # pass
      rescue SystemCallError => e
        log(
          :fatal,
          "Unable to delete LXCFS cgroup at #{cgroup_dir}: #{e.message} (#{e.class})"
        )
      end
    end

    # Change owner
    # @param uid [Integer]
    # @param gid [Integer]
    def chown(uid, gid)
      @uid = uid
      @gid = gid

      begin
        File.chown(uid, gid, mountroot)
      rescue Errno::ENOENT
      end
    end

    def configure(loadavg: true, cfs: true)
      @loadavg = loadavg
      @cfs = cfs
      create
    end

    def reconfigure
      create if exist?
    end

    # Start LXCFS if it is not already running
    def ensure_start
      start
      sv_command('start') if supervised?
    end

    # Stop LXCFS if it is running
    def ensure_stop
      stop if running?
    end

    # Stop and destroy LXCFS if it was created
    def ensure_destroy
      ensure_stop
      destroy if exist?
    end

    # Block until LXCFS becomes operational or timeout occurs
    # @raise [Lxcfs::Timeout]
    def wait(timeout: nil)
      wait_until = timeout && (Time.now + timeout)

      until operational?
        if timeout && wait_until < Time.now
          log(:fatal, 'Timed while waiting for LXCFS to become operational')
          raise Lxcfs::Timeout, "Timed out while waiting for LXCFS to become operational"
        end

        log(:info, 'Waiting for LXCFS to become operational')
        sleep(1)
      end
    end

    # Get a list of files which can be mounted from this LXCFS instance
    # @return [Array<String>]
    def mount_files
      Dir.glob('proc/*', base: mountpoint)
    end

    def log_type
      "lxcfs:#{name}"
    end

    protected
    attr_reader :uid, :gid, :mode, :runsv_source, :runsv_target, :runsv_run,
      :cgroup_root, :cgroup_dir

    def exist?
      File.exist?(runsv_run)
    end

    def operational?
      File.open(File.join(mountpoint, 'proc/cpuinfo')) do |f|
        f.readline
      end
      true

    rescue SystemCallError
      false
    end

    def supervised?
      File.exist?(File.join(runsv_target, 'supervise/ok'))
    end

    def create
      cg_root = CGroup.abs_cgroup_path('cpuset', 'osctl')

      FileUtils.mkdir_p(runsv_source)
      ErbTemplate.render_to('ct/lxcfs_runsv', {
        executable: Daemon.get.config.lxcfs.path,
        name: name,
        cpuset: cpuset,
        cgroup_root: cgroup_root,
        cgroup_dir: cgroup_dir,
        options: options,
        mountpoint: mountpoint,
      }, runsv_run, perm: 0500)
    end

    def options
      ret = []
      ret << "--pidfile=#{File.join(runsv_source, 'lxcfs.pid')}"
      ret << '--enable-loadavg' if loadavg
      ret << '--enable-cfs' if cfs
      ret
    end

    def sv_command(command, timeout: 60)
      syscmd("sv -w #{timeout} #{command} \"#{runsv_target}\"")
    rescue SystemCommandFailed => e
      log(:warn, "sv #{command} failed: #{e.message}")
    end
  end
end
