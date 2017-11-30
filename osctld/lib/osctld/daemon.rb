require 'socket'

module OsCtld
  class Daemon
    include Utils::Log
    include Utils::System
    include Utils::Zfs

    RUNDIR = '/run/osctl'
    SOCKET = File.join(RUNDIR, 'osctld.sock')

    def initialize
      Thread.abort_on_exception = true
      UserList.instance

      mkdatasets
      load_users
      register_users
      register_subugids
      load_cts
      serve
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

    def serve
      log(:info, :init, "Listening on control socket at #{SOCKET}")

      Dir.mkdir(RUNDIR, 0700) unless Dir.exists?(RUNDIR)
      srv = UNIXServer.new(SOCKET)

      loop do
        begin
          c = srv.accept

        rescue Interrupt
          log(:info, :daemon, "Exiting")
          srv.close
          File.unlink(SOCKET)
          exit(false)

        else
          handle_client(c)
        end
      end
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
