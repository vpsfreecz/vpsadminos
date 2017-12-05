module OsCtld
  module RunState
    RUNDIR = '/run/osctl'
    HOOKDIR = File.join(RUNDIR, 'hooks')

    def self.create
      Dir.mkdir(RUNDIR, 0711) unless Dir.exists?(RUNDIR)
      Dir.mkdir(HOOKDIR, 0755) unless Dir.exists?(HOOKDIR)

      %w(veth-up veth-down).each do |hook|
        symlink = OsCtld.hook_run(hook)
        File.symlink(OsCtld::hook_src(hook), symlink) unless File.symlink?(symlink)
      end
    end
  end
end
