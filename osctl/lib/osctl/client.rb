require 'json'
require 'socket'

module OsCtl
  class Client
    SOCKET = '/run/osctl/osctld.sock'

    class Error < StandardError ; end

    class Response
      def initialize(resp)
        @resp = resp
      end

      def ok?
        @resp[:status] == true
      end

      def error?
        !ok?
      end

      def update?
        ok? && @resp.has_key?(:progress)
      end

      def message
        update? ? @resp[:progress] : @resp[:message]
      end

      def data
        @resp[:response]
      end

      def [](k)
        data[k]
      end

      def each(&block)
        data.each(&block)
      end
    end

    attr_reader :version

    def initialize(sock = SOCKET)
      @sock_path = sock
      @buffer = []
    end

    def open
      @sock = UNIXSocket.new(@sock_path)
      greetings = receive_version
      @version = greetings[:version]
    end

    def cmd(cmd, opts = {})
      @sock.send({:cmd => cmd, :opts => opts}.to_json + "\n", 0)
    end

    def send_io(io)
      @sock.send_io(io)
    end

    def receive
      buf = ""

      while m = @sock.recv(1024)
        buf = buf + m
        fail 'osctld closed connection' if m.nil? || m.empty?
        break if m[-1].chr == "\n"
      end

      buf.split("\n")
    end

    def receive_version
      parse(receive[0])
    end

    def receive_resp(&block)
      loop do
        if @buffer.any?
          msgs = @buffer

        else
          msgs = receive
        end

        while msgs.any?
          msg = msgs.shift

          resp = Response.new(parse(msg))

          # Proper response
          unless resp.update?
            @buffer = msgs
            return resp
          end

          # Update
          block.call(resp.message) if block
        end
      end
    end

    def response!(&block)
      ret = receive_resp(&block)
      raise Error, ret.message if ret.error?
      ret
    end

    def cmd_response(cmd, opts = {}, &block)
      cmd(cmd, opts)
      receive_resp(&block)
    end

    def cmd_response!(*args, &block)
      ret = cmd_response(*args, &block)
      raise Error, ret.message if ret.error?
      ret
    end

    def data!(&block)
      receive_resp!(&block).data
    end

    def cmd_data!(*args, &block)
      cmd_response!(*args, &block).data
    end

    def close
      @sock.close
    end

    def parse(raw)
      JSON.parse(raw, symbolize_names: true)
    end

    def socket
      @sock
    end
  end
end
