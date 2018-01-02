module OsCtld
  # This class represents a data pool
  #
  # Data pool contains users, groups and containers, both data
  # and configuration. Each user/group/ct belongs to exactly one pool.
  class Pool
    PROPERTY = 'org.vpsadminos.osctl:active'
    USER_DS = 'user'
    CT_DS = 'ct'
    CONF_DS = 'conf'

    include Lockable
    include Utils::Log
    include Utils::System
    include Utils::Zfs

    attr_reader :name

    def initialize(name)
      @name = name
      init_lock
    end

    def id
      name
    end

    def setup
      # Ensure needed datasets are present
      mkdatasets

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

    def log_type
      "pool=#{name}"
    end

    protected
    def mkdatasets
      log(:info, "Ensuring presence of base datasets and directories")
      zfs(:create, '-p', ds(USER_DS))
      zfs(:create, '-p', ds(CT_DS))
      zfs(:create, '-p', ds(CONF_DS))

      # Configuration directories
      %w(ct group user).each do |dir|
        path = File.join(conf_path, dir)
        Dir.mkdir(path) unless Dir.exist?(path)
      end
    end

    def load_users
      # TODO: resolve conflicts when importing users with the same ugid
      #   from multiple pools
      log(:info, "Loading users")

      Dir.glob(File.join(conf_path, 'user', '*.yml')).each do |f|
        name = File.basename(f)[0..(('.yml'.length+1) * -1)]
        u = User.new(self, name)
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

    def ds(path)
      File.join(name, path)
    end

    def path(ds = '')
      File.join('/', name, ds)
    end
  end
end
