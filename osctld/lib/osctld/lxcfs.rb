require 'fileutils'
require 'libosctl'

module OsCtld
  # Manage LXCFS instance using osctl-lxcfs runit service on the host
  class Lxcfs
    RUNDIR_SERVERS = File.join(RunState::LXCFS_DIR, 'servers')
    RUNDIR_RUNSVDIR = File.join(RunState::LXCFS_DIR, 'runsvdir')
    RUNDIR_MOUNTROOT = File.join(RunState::LXCFS_DIR, 'mountpoint')

    class Error < ::StandardError ; end
    class Timeout < Error ; end

    def self.assets(add)
      add.directory(
        RunState::LXCFS_DIR,
        desc: 'osctl-lxcfs root directory',
        user: 0,
        group: 0,
        mode: 0711,
      )
      add.directory(
        RUNDIR_SERVERS,
        desc: 'LXCFS runit services',
        user: 0,
        group: 0,
        mode: 0755,
      )
      add.directory(
        RUNDIR_RUNSVDIR,
        desc: 'LXCFS runsv directory',
        user: 0,
        group: 0,
        mode: 0755,
      )
      add.directory(
        RUNDIR_MOUNTROOT,
        desc: 'LXCFS mount root',
        user: 0,
        group: 0,
        mode: 0755,
      )
    end

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    # @return [String]
    attr_reader :name

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
    # @param loadavg [Boolean] enable load average tracking
    # @param cfs [Boolean] enable virtualized CPU usage view based on CFS quotas
    def initialize(name, uid:, gid:, loadavg: true, cfs: true)
      @name = name
      @uid = uid
      @gid = gid
      @loadavg = loadavg
      @cfs = cfs
      @runsv_source = File.join(RUNDIR_SERVERS, name)
      @runsv_target = File.join(RUNDIR_RUNSVDIR, name)
      @runsv_run = File.join(runsv_source, 'run')
      @mountroot = File.join(RUNDIR_MOUNTROOT, name)
      @mountpoint = File.join(mountroot, 'mount')
    end

    def running?
      Dir.exist?(runsv_target)
    end

    def start
      create unless exist?

      log(:info, "Starting LXCFS")

      FileUtils.mkdir_p(mountroot)
      File.chown(uid, gid, mountroot)
      File.chmod(0550, mountroot)
      File.symlink(runsv_source, runsv_target)
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
      start unless running?
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
    attr_reader :name, :uid, :gid, :runsv_source, :runsv_target, :runsv_run

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

    def create
      FileUtils.mkdir_p(runsv_source)
      ErbTemplate.render_to('ct/lxcfs_runsv', {
        executable: Daemon.get.config.lxcfs,
        name: name,
        options: options,
        mountpoint: mountpoint,
      }, runsv_run, perm: 0500)
    end

    def options
      ret = []
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
