require 'fiddle'
require 'fiddle/import'

module OsCtld
  module Mount::Sys
    module Int
      extend Fiddle::Importer
      dlload Fiddle.dlopen(nil)

      MS_MGC_VAL = 0xc0ed0000
      MS_BIND = 4096
      MS_MOVE = 8192

      extern 'int mount(const char *source, const char *target, '+
            '          const char *filesystemtype, unsigned long mountflags, '+
            '          const void *data)'

      extern 'int umount2(const char *target, int flags)'
    end

    def self.move_mount(src, dst)
      ret = Int.mount(src, dst, 0, Int::MS_MGC_VAL | Int::MS_MOVE, 0)
      raise SystemCallError, Fiddle.last_error if ret != 0
      ret
    end

    def self.bind_mount(src, dst)
      ret = Int.mount(src, dst, 0, Int::MS_MGC_VAL | Int::MS_BIND, 0)
      raise SystemCallError, Fiddle.last_error if ret != 0
      ret
    end

    def self.unmount(mountpoint)
      ret = Int.umount2(mountpoint, 0) # force unmount returns EACCESS
      raise SystemCallError, Fiddle.last_error if ret != 0
      ret
    end
  end
end
