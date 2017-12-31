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

      def message
        @resp[:message]
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
        break if m[-1].chr == "\n"
      end

      buf
    end

    def receive_version
      parse(receive)
    end

    def receive_resp
      Response.new(parse(receive))
    end

    def response!
      ret = receive_resp
      raise Error, ret.message if ret.error?
      ret
    end

    def cmd_response(cmd, opts = {})
      cmd(cmd, opts)
      receive_resp
    end

    def cmd_response!(*args)
      ret = cmd_response(*args)
      raise Error, ret.message if ret.error?
      ret
    end

    def data!
      receive_resp!.data
    end

    def cmd_data!(*args)
      cmd_response!(*args).data
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
