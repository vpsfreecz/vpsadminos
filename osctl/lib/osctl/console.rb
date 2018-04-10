module OsCtl
  class Console
    END_SEQ = ["\x01", "q"]

    def self.open(socket, input, output)
      c = new(socket, input, output)
      c.open
    end

    def initialize(socket, input, output)
      @socket = socket
      @in = input
      @out = output
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

    def close
      @socket.close
    end

    protected
    def read_in
      data = @in.read_nonblock(4096)

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

      @socket.write(@buffer)
      @socket.flush
      @buffer.clear
    end
  end
end
