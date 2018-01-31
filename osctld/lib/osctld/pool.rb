module OsCtld
  # This class represents a data pool
  #
  # Data pool contains users, groups and containers, both data
  # and configuration. Each user/group/ct belongs to exactly one pool.
  class Pool
    PROPERTY_ACTIVE = 'org.vpsadminos.osctl:active'
    PROPERTY_DATASET = 'org.vpsadminos.osctl:dataset'
    USER_DS = 'user'
    CT_DS = 'ct'
    CONF_DS = 'conf'
    LOG_DS = 'log'

    include Lockable
    include Utils::Log
    include Utils::System
    include Utils::Zfs

    attr_reader :name, :dataset, :migration_key_chain

    def initialize(name, dataset)
      @name = name
      @dataset = dataset || name
      @migration_key_chain = Migration::KeyChain.new(self)
      init_lock
    end

    def id
      name
    end

    def pool
      self
    end

    def setup
      # Ensure needed datasets are present
      mkdatasets

      # Setup run state, i.e. hooks
      runstate

      # Load users from zpool
      load_users

      # Register loaded users into the system
      Commands::User::Register.run(all: true)

      # Generate /etc/subuid and /etc/subgid
      Commands::User::SubUGIds.run

      # Load groups
      load_groups

      # Load containers from zpool
      load_cts

      # Allow containers to create veth interfaces
      Commands::User::LxcUsernet.run

      # Load migration keys
      migration_key_chain.setup

      # Open history
      History.open(self)
    end

    def ct_ds
      ds(CT_DS)
    end

    def user_ds
      ds(USER_DS)
    end

    def conf_path
      path(CONF_DS)
    end

    def log_path
      path(LOG_DS)
    end

    def log_type
      "pool=#{name}"
    end

    def run_dir
      File.join(RunState::POOL_DIR, name)
    end

    def hook_dir
      File.join(run_dir, 'hooks')
    end

    def console_dir
      File.join(RunState::POOL_DIR, name, 'console')
    end

    protected
    def mkdatasets
      log(:info, "Ensuring presence of base datasets and directories")
      zfs(:create, '-p', ds(USER_DS))
      zfs(:create, '-p', ds(CT_DS))
      zfs(:create, '-p', ds(CONF_DS))
      zfs(:create, '-p', ds(LOG_DS))

      # Configuration directories
      %w(ct group user migration).each do |dir|
        path = File.join(conf_path, dir)
        Dir.mkdir(path) unless Dir.exist?(path)
      end

      path = File.join(log_path, 'ct')
      Dir.mkdir(path) unless Dir.exist?(path)
    end

    def load_users
      log(:info, "Loading users")

      Dir.glob(File.join(conf_path, 'user', '*.yml')).each do |f|
        name = File.basename(f)[0..(('.yml'.length+1) * -1)]
        u = User.new(self, name)
        next unless check_user_conflict(u)

        DB::Users.add(u)
        UserControl::Supervisor.start_server(u)
      end
    end

    def load_groups
      log(:info, "Loading groups")
      DB::Groups.setup(self)

      Dir.glob(File.join(conf_path, 'group', '*.yml')).each do |grp|
        name = File.basename(grp)[0..(('.yml'.length+1) * -1)]
        next if %w(root default).include?(name)

        DB::Groups.add(Group.new(self, name))
      end
    end

    def load_cts
      log(:info, "Loading containers")

      Dir.glob(File.join(conf_path, 'ct', '*.yml')).each do |f|
        ctid = File.basename(f)[0..(('.yml'.length+1) * -1)]

        ct = Container.new(self, ctid)
        Monitor::Master.monitor(ct)
        Console.reconnect_tty0(ct) if ct.current_state == :running
        DB::Containers.add(ct)
      end
    end

    def runstate
      Dir.mkdir(run_dir, 0711) unless Dir.exist?(run_dir)

      [console_dir, hook_dir].each do |dir|
        Dir.mkdir(dir, 0711) unless Dir.exist?(dir)
      end

      %w(ct-start).each do |hook|
        symlink = OsCtld.hook_run(hook, self)
        File.symlink(OsCtld::hook_src(hook), symlink) unless File.symlink?(symlink)
      end
    end

    def check_user_conflict(user)
      DB::Users.get.each do |u|
        if u.name == user.name
          log(
            :warn,
            "Unable to load user '#{user.name}': "+
            "name already taken by pool '#{u.pool.name}'"
          )
          return false

        elsif u.ugid == user.ugid
          log(
            :warn,
            "Unable to load user '#{user.name}': "+
            "user/group ID #{user.ugid} already taken by pool '#{u.pool.name}'"
          )
          return false
        end
      end

      true
    end

    def ds(path)
      File.join(dataset, path)
    end

    def path(ds = '')
      File.join('/', dataset, ds)
    end
  end
end
