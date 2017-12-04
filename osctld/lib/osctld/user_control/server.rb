require 'socket'
require 'thread'

module OsCtld
  class UserControl::Server
    include Utils::Log

    def start(user)
      @path = socket_path(user)
      log(:info, :user_control, "Listening on user control socket at #{@path}")

      @srv = UNIXServer.new(@path)

      File.chown(0, user.ugid, @path)
      File.chmod(0660, @path)

      loop do
        begin
          c = @srv.accept

        rescue IOError
          return

        else
          handle_client(c, user)
        end
      end
    end

    def stop
      @srv.close
      File.unlink(@path)
    end

    private
    def handle_client(client, user)
      log(:info, :user_control, 'Received a new client connection')

      Thread.new do
        c = UserControl::ClientHandler.new(client, user)
        c.communicate
      end
    end

    def socket_path(user)
      File.join(user.userdir, '.osctld.sock')
    end
  end
end
