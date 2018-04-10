require 'base64'
require 'json'

module OsCtl
  class Console
    END_SEQ = ["\x01", "q"]

    def self.open(socket, input, output)
      c = new(socket, input, output)
      c.open
    end

    def initialize(socket, input, output, raw: false)
      @socket = socket
      @in = input
      @out = output
      @raw = raw
      @private_buffer = ''
      @buffer = ''
      @end_i = 0
    end

    def open
      loop do
        rs, = IO.select([@socket, @in])

        rs.each do |io|
          case io
          when @socket
            @out.write(@socket.read_nonblock(4096))
            @out.flush

          when @in
            break if read_in == :stop
          end
        end
      end

    rescue IOError
    end

    def resize(rows, cols)
      send_cmd(rows: rows, cols: cols)
    end

    def close
      @socket.close
    end

    protected
    def raw?
      @raw
    end

    def read_in
      data = @in.read_nonblock(4096)

      if raw?
        @socket.write(data)
        @socket.flush
        return
      end

      data.each_char do |char|
        if char == END_SEQ[ @end_i ]
          if @end_i == END_SEQ.size-1
            @socket.close
            return :stop
          end

          @end_i += 1

          if @end_i == 1
            @private_buffer += char

          else
            @buffer += char
          end

        elsif char == END_SEQ.first
          @private_buffer += char

        else
          @end_i = 0

          unless @private_buffer.empty?
            @buffer += @private_buffer
            @private_buffer.clear
          end

          @buffer += char
        end
      end

      send_cmd(keys: Base64.strict_encode64(@buffer))
      @buffer.clear
    end

    def send_cmd(hash)
      @socket.write(hash.to_json + "\n")
      @socket.flush
    end
  end
end
