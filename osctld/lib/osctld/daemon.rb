require 'socket'

module OsCtld
  class Daemon
    include Utils::Log
    include Utils::System
    include Utils::Zfs

    SOCKET = File.join(RunState::RUNDIR, 'osctld.sock')

    def initialize
      Thread.abort_on_exception = true
      UserList.instance
      ContainerList.instance
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

      conf_ct = File.join('/', CONF_DS, 'ct')
      Dir.mkdir(conf_ct) unless Dir.exist?(conf_ct)
    end

    def load_users
      log(:info, :init, "Loading users from data pool")

      out = zfs(:list, '-H -r -t filesystem -d 1 -o name', USER_DS)[:output]

      out.split("\n")[1..-1].map do |line|
        UserList.add(User.new(line.strip.split('/').last))
      end
    end

    def load_cts
      log(:info, :init, "Loading containers from data pool")

      out = zfs(:list, '-H -r -t filesystem -d 1 -o name', CT_DS)[:output]

      out.split("\n")[1..-1].map do |line|
        ctid = line.strip.split('/').last

        ct = Container.new(ctid)
        Monitor::Master.monitor(ct)
        Console.reconnect_tty0(ct) if ct.current_state == :running
        ContainerList.add(ct)
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
