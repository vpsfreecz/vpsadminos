require 'socket'
require 'thread'
require 'osctld/generic/client_handler'

module OsCtld
  class Migration::Server
    class ClientHandler < Generic::ClientHandler
      def handle_cmd(req)
        cmd = Migration::Command.find(req[:cmd].to_sym)
        error!("Unsupported command '#{req[:cmd]}'") unless cmd

        cmd.run(req[:opts], handler: self)
      end

      def log_type
        self.class.name
      end
    end

    @@instance = nil

    def self.instance
      @@instance = new unless @@instance
      @@instance
    end

    class << self
      %i(start stop assets).each do |v|
        define_method(v) do |*args, &block|
          instance.send(v, *args, &block)
        end
      end
    end

    private
    def initialize
    end

    public
    def start
      socket = UNIXServer.new(Migration::SOCKET)
      File.chown(Migration::UID, 0, Migration::SOCKET)
      File.chmod(0600, Migration::SOCKET)

      @server = Generic::Server.new(socket, ClientHandler)
      @thread = Thread.new { @server.start }
    end

    def stop
      @server.close
      @thread.join
      File.unlink(Migration::SOCKET)
    end

    def assets(add)
      add.socket(
        Migration::SOCKET,
        desc: 'Socket for migration control',
        user: Migration::UID,
        group: 0,
        mode: 0600
      )
    end
  end
end
