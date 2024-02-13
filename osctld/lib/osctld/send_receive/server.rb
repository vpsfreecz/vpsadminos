require 'socket'
require 'thread'
require 'osctld/generic/client_handler'

module OsCtld
  class SendReceive::Server
    class ClientHandler < Generic::ClientHandler
      def handle_cmd(req)
        cmd = SendReceive::Command.find(req[:cmd].to_sym)
        error!("Unsupported command '#{req[:cmd]}'") unless cmd

        cmd.run(internal: { handler: self }, **req[:opts])
      end

      def log_type
        self.class.name
      end
    end

    @@instance = nil

    def self.instance
      @@instance ||= new
      @@instance
    end

    class << self
      %i[start stop assets].each do |v|
        define_method(v) do |*args, &block|
          instance.send(v, *args, &block)
        end
      end
    end

    private

    def initialize; end

    public

    def start
      socket = UNIXServer.new(SendReceive::SOCKET)
      File.chown(SendReceive::UID, 0, SendReceive::SOCKET)
      File.chmod(0o600, SendReceive::SOCKET)

      @server = Generic::Server.new(socket, ClientHandler)
      @thread = Thread.new { @server.start }
    end

    def stop
      @server.stop
      @thread.join
      File.unlink(SendReceive::SOCKET)
    end

    def assets(add)
      add.socket(
        SendReceive::SOCKET,
        desc: 'Socket for send/receive control',
        user: SendReceive::UID,
        group: 0,
        mode: 0o600
      )
    end
  end
end
