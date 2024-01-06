module OsCtld
  module RunState
    RUNDIR = '/run/osctl'
    POOL_DIR = File.join(RUNDIR, 'pools')
    USER_CONTROL_DIR = File.join(RUNDIR, 'user-control')
    SEND_RECEIVE_DIR = File.join(RUNDIR, 'send-receive')
    REPOSITORY_DIR = File.join(RUNDIR, 'repository')
    CONFIG_DIR = File.join(RUNDIR, 'configs')
    OSCTLD_CONFIG_DIR = File.join(CONFIG_DIR, 'osctld')
    LXC_CONFIG_DIR = File.join(CONFIG_DIR, 'lxc')
    APPARMOR_DIR = File.join(CONFIG_DIR, 'apparmor')
    CPU_SCHEDULER_DIR = File.join(RUNDIR, 'cpu-scheduler')
    SHUTDOWN_MARKER = File.join(RUNDIR, 'shutdown')
    CGROUP_VERSION = File.join(RUNDIR, 'cgroup.version')

    def self.create
      mkdir_p(RUNDIR, 0711)
      mkdir_p(POOL_DIR, 0711)
      mkdir_p(USER_CONTROL_DIR, 0711)
      mkdir_p(SEND_RECEIVE_DIR, 0100, uid: SendReceive::UID, gid: 0)

      # Bundler needs to have some place to store its temp files
      mkdir_p(REPOSITORY_DIR, 0700, uid: Repository::UID, gid: 0)

      # LXC configs
      mkdir_p(CONFIG_DIR, 0755)
      mkdir_p(LXC_CONFIG_DIR, 0755)

      Lxc.install_lxc_configs(LXC_CONFIG_DIR)

      # AppArmor files
      mkdir_p(APPARMOR_DIR, 0755)

      mkdir_p(CPU_SCHEDULER_DIR, 0755)
    end

    # @return [RunState::StartConfig]
    def self.open_start_config
      StartConfig.new(File.join(OSCTLD_CONFIG_DIR, 'start-config.json'))
    end

    def self.assets(add)
      add.directory(
        RunState::RUNDIR,
        desc: 'Runtime configuration',
        user: 0,
        group: 0,
        mode: 0711
      )
      add.directory(
        RunState::POOL_DIR,
        desc: 'Runtime pool configuration',
        user: 0,
        group: 0,
        mode: 0711
      )
      add.directory(
        RunState::USER_CONTROL_DIR,
        desc: 'Runtime user configuration',
        user: 0,
        group: 0,
        mode: 0711
      )
      add.directory(
        RunState::SEND_RECEIVE_DIR,
        desc: 'Send/Receive configuration',
        user: SendReceive::UID,
        group: 0,
        mode: 0100,
        optional: true
      )
      add.directory(
        RunState::REPOSITORY_DIR,
        desc: 'Home directory for the repository user',
        user: Repository::UID,
        group: 0,
        mode: 0700
      )
      add.directory(
        RunState::CONFIG_DIR,
        desc: 'Global LXC configuration files',
        user: 0,
        group: 0,
        mode: 0755
      )

      if AppArmor.enabled?
        add.directory(
          RunState::APPARMOR_DIR,
          desc: 'Shared AppArmor files',
          user: 0,
          group: 0,
          mode: 0755
        )
      end

      SendReceive.assets(add)
      CpuScheduler.assets(add)
    end

    def self.mkdir_p(path, mode, uid: nil, gid: nil)
      begin
        Dir.mkdir(path, mode)
      rescue Errno::EEXIST
        File.chmod(mode, path)
      end

      File.chown(uid, gid, path) if uid && gid
    end
  end
end
