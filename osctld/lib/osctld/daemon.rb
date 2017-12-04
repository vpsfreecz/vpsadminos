require 'socket'

module OsCtld
  class Daemon
    include Utils::Log
    include Utils::System
    include Utils::Zfs

    RUNDIR = '/run/osctl'
    HOOKDIR = File.join(RUNDIR, 'hooks')
    SOCKET = File.join(RUNDIR, 'osctld.sock')

    def initialize
      Thread.abort_on_exception = true
      UserList.instance
      ContainerList.instance
    end

    def setup
      setup_rundir
      mkdatasets
      load_users
      register_users
      register_subugids
      load_cts
      configure_lxc_usernet
      start_user_control
      serve
    end

    def setup_rundir
      Dir.mkdir(RUNDIR, 0711) unless Dir.exists?(RUNDIR)
      Dir.mkdir(HOOKDIR, 0755) unless Dir.exists?(HOOKDIR)

      %w(veth-up veth-down).each do |hook|
        symlink = OsCtld.hook_run(hook)
        File.symlink(OsCtld::hook_src(hook), symlink) unless File.symlink?(symlink)
      end
    end

    def mkdatasets
      log(:info, :init, "Ensuring presence of dataset #{USER_DS}")
      zfs(:create, '-p', USER_DS)
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

      out = zfs(:list, '-H -r -t filesystem -d 3 -o name', USER_DS)[:output]

      out.split("\n").map do |line|
        parts = line.strip.split('/')

        # lxc/user/<user>/ct/<id>
        next if parts.count < 5

        user = parts[2]
        ctid = parts[4]

        ContainerList.add(Container.new(ctid, user))
      end
    end

    def register_users
      Commands::User::Register.run(all: true)
    end

    def register_subugids
      Commands::User::SubUGIds.run
    end

    def configure_lxc_usernet
      Commands::User::LxcUsernet.run
    end

    def start_user_control
      UserControl.setup
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
