require 'json'
require 'socket'

module OsCtl
  class Client
    SOCKET = '/run/osctl/osctld.sock'

    attr_reader :version

    def initialize(sock = SOCKET)
      @sock_path = sock
    end

    def open
      @sock = UNIXSocket.new(@sock_path)
      greetings = reply
      @version = greetings[:version]
    end

    def cmd(cmd, opts = {})
      @sock.send({:cmd => cmd, :opts => opts}.to_json + "\n", 0)
    end

    def send_io(io)
      @sock.send_io(io)
    end

    def reply
      buf = ""

      while m = @sock.recv(1024)
        buf = buf + m
        break if m[-1].chr == "\n"
      end

      parse(buf)
    end

    def response
      reply[:response]
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
