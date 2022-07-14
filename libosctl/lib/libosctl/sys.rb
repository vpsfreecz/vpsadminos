require 'fiddle'
require 'fiddle/import'

module OsCtl::Lib
  class Sys
    CLONE_NEWNS = 0x00020000
    CLONE_NEWUTS = 0x04000000
    CLONE_NEWUSER = 0x10000000
    CLONE_NEWPID = 0x20000000
    CLONE_NEWNET = 0x40000000
    CLONE_NEWIPC = 0x08000000

    MS_MGC_VAL = 0xc0ed0000
    MS_NOSUID = 2
    MS_NODEV = 4
    MS_NOEXEC = 8
    MS_BIND = 4096
    MS_MOVE = 8192
    MS_REC = 16384
    MS_SLAVE = 1 << 19
    MS_SHARED = 1 << 20

    module Int
      extend Fiddle::Importer
      dlload Fiddle.dlopen(nil)

      MNT_DETACH = 2

      extern 'int setresuid(unsigned int ruid, unsigned int euid, unsigned int suid)'
      extern 'int setresgid(unsigned int rgid, unsigned int egid, unsigned int sgid)'
      extern 'int mount(const char *source, const char *target, '+
             '          const char *filesystemtype, unsigned long mountflags, '+
             '          const void *data)'

      extern 'int umount2(const char *target, int flags)'
      extern 'int unshare(int flags)'
      extern 'int setns(int fd, int nstype)'
      extern 'int chroot(const char *path)'
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

    def rbind_mount(src, dst)
      ret = Int.mount(src, dst, 0, MS_MGC_VAL | MS_BIND | MS_REC, 0)
      raise SystemCallError, Fiddle.last_error if ret != 0
      ret
    end

    def mount_tmpfs(dst, name: 'none', flags: MS_MGC_VAL, options: 0)
      ret = Int.mount(name, dst, "tmpfs", flags, options)
      raise SystemCallError, Fiddle.last_error if ret != 0
      ret
    end

    def mount_proc(dst)
      ret = Int.mount("none", dst, "proc", MS_MGC_VAL, 0)
      raise SystemCallError, Fiddle.last_error if ret != 0
      ret
    end

    def make_shared(dst)
      ret = Int.mount("none", dst, 0, MS_SHARED, 0)
      raise SystemCallError, Fiddle.last_error if ret != 0
      ret
    end

    def make_rshared(dst)
      ret = Int.mount("none", dst, 0, MS_REC | MS_SHARED, 0)
      raise SystemCallError, Fiddle.last_error if ret != 0
      ret
    end

    def make_slave(dst)
      ret = Int.mount("none", dst, 0, MS_SLAVE, 0)
      raise SystemCallError, Fiddle.last_error if ret != 0
      ret
    end

    def make_rslave(dst)
      ret = Int.mount("none", dst, 0, MS_REC | MS_SLAVE, 0)
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
      ret = Int.setns(f.fileno, nstype)
      f.close
      raise SystemCallError, Fiddle.last_error if ret != 0
      ret
    end

    def setns_io(io, nstype)
      ret = Int.setns(io.fileno, nstype)
      raise SystemCallError, Fiddle.last_error if ret != 0
      ret
    end

    def unshare_ns(type)
      ret = Int.unshare(type)
      raise SystemCallError, Fiddle.last_error if ret != 0
      ret
    end

    def chroot(path)
      ret = Int.chroot(path)
      raise SystemCallError, Fiddle.last_error if ret != 0
      ret
    end
  end
end
