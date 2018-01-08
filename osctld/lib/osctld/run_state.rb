module OsCtld
  module RunState
    RUNDIR = '/run/osctl'
    POOL_DIR = File.join(RUNDIR, 'pools')
    USER_CONTROL_DIR = File.join(RUNDIR, 'user-control')

    def self.create
      Dir.mkdir(RUNDIR, 0711) unless Dir.exists?(RUNDIR)
      Dir.mkdir(POOL_DIR, 0755) unless Dir.exists?(POOL_DIR)
      Dir.mkdir(USER_CONTROL_DIR, 0711) unless Dir.exists?(USER_CONTROL_DIR)
    end
  end
end
