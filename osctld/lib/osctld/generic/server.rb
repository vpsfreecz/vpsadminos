module OsCtld
  # Generic socket server
  #
  # A thread is spawned for every connected client. An instance of
  # {Generic::ClientHandler} or its subclass is created to handle the connection.
  class Generic::Server
    # @param socket [BasicSocket] server socket
    # @param client_handler [Generic::ClientHandler] name of a class that will
    #   be instantiated for every client
    # @param opts [Hash] options
    # @option opts [Hash] opts options passed to the client handler
    def initialize(socket, client_handler, opts = {})
      @socket = socket
      @client_handler = client_handler
      @opts = opts
    end

    def start
      loop do
        c = @socket.accept
      rescue IOError
        return
      else
        handle_client(c)
      end
    end

    def stop
      @socket.close
    end

    protected

    def handle_client(socket)
      c = @client_handler.new(socket, @opts[:opts] || {})
      t = Thread.new { c.communicate }
      ThreadReaper.add(t, c)
    end
  end
end
