require 'fiddle'
require 'fiddle/import'
require 'io/wait'
require 'tempfile'
require 'libosctl/native'

module OsCtl::Lib
  class Sys
    CLONE_NEWNS = 0x00020000
    CLONE_NEWUTS = 0x04000000
    CLONE_NEWUSER = 0x10000000
    CLONE_NEWPID = 0x20000000
    CLONE_NEWNET = 0x40000000
    CLONE_NEWIPC = 0x08000000

    O_CLOEXEC = 0x0008_0000

    MS_MGC_VAL = 0xc0ed0000
    MS_RDONLY = 1
    MS_NOSUID = 2
    MS_NODEV = 4
    MS_NOEXEC = 8
    MS_REMOUNT = 32
    MS_BIND = 4096
    MS_MOVE = 8192
    MS_REC = 16_384
    MS_PRIVATE = 1 << 18
    MS_SLAVE = 1 << 19
    MS_SHARED = 1 << 20

    SYSLOGNS_MAX_TAG_BYTESIZE = 12

    module Int
      extend Fiddle::Importer
      dlload Fiddle.dlopen(nil)

      MNT_DETACH = 2

      extern 'int setresuid(unsigned int ruid, unsigned int euid, unsigned int suid)'
      extern 'int setresgid(unsigned int rgid, unsigned int egid, unsigned int sgid)'
      extern 'int mount(const char *source, const char *target,           ' \
             'const char *filesystemtype, unsigned long mountflags,           ' \
             'const void *data)'

      extern 'int umount2(const char *target, int flags)'
      extern 'int unshare(int flags)'
      extern 'int chroot(const char *path)'
      extern 'int fchdir(int fd)'
      extern 'int syncfs(int fd)'
      extern 'int klogctl(int type, char *bufp, int len)'
      extern 'int pidfd_open(int pid, unsigned int flags)'
      extern 'int openat(int dirfd, const char *pathname, int flags, unsigned int mode)'
    end

    def setresuid(ruid, euid, suid)
      ret = Int.setresuid(ruid, euid, suid)
      raise SystemCallError, Fiddle.last_error if ret != 0

      ret
    end

    def setresgid(rgid, egid, sgid)
      ret = Int.setresgid(rgid, egid, sgid)
      raise SystemCallError, Fiddle.last_error if ret != 0

      ret
    end

    def pidfd_open(pid)
      fd = Int.pidfd_open(pid, 0)
      raise SystemCallError, Fiddle.last_error if fd < 0

      IO.for_fd(fd, autoclose: true)
    end

    def pidfd_alive?(pidfd)
      pidfd.wait_readable(0).nil?
    end

    # Open a procfs path relative to an already-open /proc/<pid> directory.
    # This deliberately permits procfs magic links so the retained directory,
    # rather than a reused numeric PID, remains the resolution authority.
    def openat_io(dir, path, flags: File::RDONLY, mode: 0)
      relative_path = path.to_s
      if relative_path.empty? || relative_path.start_with?('/') || relative_path.include?("\0") ||
         relative_path.split('/').include?('..')
        raise ArgumentError, 'path has to be a safe relative path'
      end

      fd = Int.openat(dir.fileno, relative_path, Integer(flags) | O_CLOEXEC, Integer(mode))
      raise SystemCallError, Fiddle.last_error if fd < 0

      IO.for_fd(fd, autoclose: true).tap { |io| io.close_on_exec = true }
    end

    def move_mount(src, dst)
      ret = Int.mount(src, dst, 0, MS_MGC_VAL | MS_MOVE, 0)
      raise SystemCallError, Fiddle.last_error if ret != 0

      ret
    end

    def bind_mount(src, dst)
      ret = Int.mount(src, dst, 0, MS_MGC_VAL | MS_BIND, 0)
      raise SystemCallError, Fiddle.last_error if ret != 0

      ret
    end

    def bind_mount_readonly(src, dst)
      bind_mount(src, dst)

      ret = Int.mount('none', dst, 0, MS_MGC_VAL | MS_BIND | MS_REMOUNT | MS_RDONLY, 0)
      raise SystemCallError, Fiddle.last_error if ret != 0

      ret
    end

    def rbind_mount(src, dst)
      ret = Int.mount(src, dst, 0, MS_MGC_VAL | MS_BIND | MS_REC, 0)
      raise SystemCallError, Fiddle.last_error if ret != 0

      ret
    end

    def mount_tmpfs(dst, name: 'none', flags: MS_MGC_VAL, options: 0)
      ret = Int.mount(name, dst, 'tmpfs', flags, options)
      raise SystemCallError, Fiddle.last_error if ret != 0

      ret
    end

    def mount_proc(dst)
      ret = Int.mount('none', dst, 'proc', MS_MGC_VAL, 0)
      raise SystemCallError, Fiddle.last_error if ret != 0

      ret
    end

    def make_shared(dst)
      ret = Int.mount('none', dst, 0, MS_SHARED, 0)
      raise SystemCallError, Fiddle.last_error if ret != 0

      ret
    end

    def make_private(dst)
      ret = Int.mount('none', dst, 0, MS_PRIVATE, 0)
      raise SystemCallError, Fiddle.last_error if ret != 0

      ret
    end

    def make_rshared(dst)
      ret = Int.mount('none', dst, 0, MS_REC | MS_SHARED, 0)
      raise SystemCallError, Fiddle.last_error if ret != 0

      ret
    end

    def make_slave(dst)
      ret = Int.mount('none', dst, 0, MS_SLAVE, 0)
      raise SystemCallError, Fiddle.last_error if ret != 0

      ret
    end

    def make_rslave(dst)
      ret = Int.mount('none', dst, 0, MS_REC | MS_SLAVE, 0)
      raise SystemCallError, Fiddle.last_error if ret != 0

      ret
    end

    def unmount(mountpoint)
      ret = Int.umount2(mountpoint, 0) # force unmount returns EACCESS
      raise SystemCallError, Fiddle.last_error if ret != 0

      ret
    end

    def unmount_lazy(mountpoint)
      ret = Int.umount2(mountpoint, Int::MNT_DETACH)
      raise SystemCallError, Fiddle.last_error if ret != 0

      ret
    end

    def setns_path(path, nstype)
      f = File.open(path)
      Native.setns(f.fileno, nstype)

      nil
    ensure
      f.close if f
    end

    def setns_io(io, nstype)
      Native.setns(io.fileno, nstype)
      nil
    end

    def unshare_ns(type)
      Native.unshare(type)
      nil
    end

    def chroot(path)
      ret = Int.chroot(path)
      raise SystemCallError, Fiddle.last_error if ret != 0

      ret
    end

    def fchdir_io(io)
      ret = Int.fchdir(io.fileno)
      raise SystemCallError, Fiddle.last_error if ret != 0

      ret
    end

    # @param tag [String] syslogns tag prepended to all messages
    def create_syslogns(tag)
      if tag.bytesize > SYSLOGNS_MAX_TAG_BYTESIZE
        raise ArgumentError, "tag can have at most #{SYSLOGNS_MAX_TAG_BYTESIZE} bytes"
      end

      klogctl_ret = Int.klogctl(11, tag, tag.bytesize)
      raise SystemCallError, Fiddle.last_error if klogctl_ret != 0

      unshare_ret = Int.unshare(0)
      raise SystemCallError, Fiddle.last_error if unshare_ret != 0

      0
    end

    # @param pid [Integer] attach to syslogns of PID
    def attach_syslogns(pid)
      setns_path(File.join('/proc', pid.to_s, 'ns/syslog'), 0)
    end

    # @param path [String] filesystem directory
    def syncfs(path)
      f = Tempfile.new('.syncfs', path)
      ret = Int.syncfs(f.fileno)
      raise SystemCallError, Fiddle.last_error if ret != 0

      ret
    ensure
      f.close
      f.unlink
    end
  end
end
