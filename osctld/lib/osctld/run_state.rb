module OsCtld
  module RunState
    RUNDIR = '/run/osctl'
    HOOKDIR = File.join(RUNDIR, 'hooks')
    USER_CONTROL_DIR = File.join(RUNDIR, 'user-control')
    CONSOLE_DIR = File.join(RUNDIR, 'console')

    def self.create
      Dir.mkdir(RUNDIR, 0711) unless Dir.exists?(RUNDIR)
      Dir.mkdir(HOOKDIR, 0755) unless Dir.exists?(HOOKDIR)
      Dir.mkdir(USER_CONTROL_DIR, 0711) unless Dir.exists?(USER_CONTROL_DIR)
      Dir.mkdir(CONSOLE_DIR, 0711) unless Dir.exists?(CONSOLE_DIR)

      %w(ct-start).each do |hook|
        symlink = OsCtld.hook_run(hook)
        File.symlink(OsCtld::hook_src(hook), symlink) unless File.symlink?(symlink)
      end
    end
  end
end
