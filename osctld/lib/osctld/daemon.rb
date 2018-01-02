require 'socket'

module OsCtld
  class Daemon
    include Utils::Log
    include Utils::System
    include Utils::Zfs

    SOCKET = File.join(RunState::RUNDIR, 'osctld.sock')

    def initialize
      Thread.abort_on_exception = true
      DB::Users.instance
      DB::Groups.instance
      DB::Containers.instance
      Console.init
    end

    def setup
      # Setup /run/osctl
      RunState.create

      # Ensure needed datasets are present
      mkdatasets

      # Increase alloed number of open files
      syscmd("prlimit --nofile=4096 --pid #{Process.pid}")

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

      # Start user control server, used for lxc hooks
      UserControl.setup

      # Start accepting client commands
      serve
    end

    def mkdatasets
      log(:info, :init, "Ensuring presence of base datasets and directories")
      zfs(:create, '-p', USER_DS)
      zfs(:create, '-p', CT_DS)
      zfs(:create, '-p', CONF_DS)

      # Configuration directories
      %w(ct group user).each do |dir|
        path = File.join('/', CONF_DS, dir)
        Dir.mkdir(path) unless Dir.exist?(path)
      end
    end

    def load_users
      log(:info, :init, "Loading users")

      Dir.glob(File.join('/', OsCtld::CONF_DS, 'user', '*.yml')).each do |f|
        name = File.basename(f)[0..(('.yml'.length+1) * -1)]
        DB::Users.add(User.new(name))
      end
    end

    def load_groups
      log(:info, :init, "Loading groups")
      DB::Groups.setup

      Dir.glob(File.join('/', CONF_DS, 'group', '*.yml')).each do |grp|
        name = File.basename(grp)[0..(('.yml'.length+1) * -1)]
        next if %w(root default).include?(name)

        DB::Groups.add(Group.new(name))
      end
    end

    def load_cts
      log(:info, :init, "Loading containers")

      Dir.glob(File.join('/', OsCtld::CONF_DS, 'ct', '*.yml')).each do |f|
        ctid = File.basename(f)[0..(('.yml'.length+1) * -1)]

        ct = Container.new(ctid)
        Monitor::Master.monitor(ct)
        Console.reconnect_tty0(ct) if ct.current_state == :running
        DB::Containers.add(ct)
      end
    end

    def serve
      log(:info, :init, "Listening on control socket at #{SOCKET}")

      @srv = UNIXServer.new(SOCKET)
      File.chmod(0600, SOCKET)

      loop do
        begin
          c = @srv.accept

        rescue IOError
          return

        else
          handle_client(c)
        end
      end
    end

    def stop
      log(:info, :daemon, "Exiting")
      @srv.close if @srv
      File.unlink(SOCKET) if File.exist?(SOCKET)
      UserControl.stop
      Monitor::Master.stop
      exit(false)
    end

    private
    def handle_client(client)
      log(:info, :server, 'Received a new client connection')

      Thread.new do
        c = ClientHandler.new(client)
        c.communicate
      end
    end
  end
end
