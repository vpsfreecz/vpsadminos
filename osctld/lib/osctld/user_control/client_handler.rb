module OsCtld
  class UserControl::ClientHandler
    include Utils::Log

    def initialize(socket, user)
      @sock = socket
      @user = user
    end

    def communicate
      buf = ""

      while m = @sock.recv(1024)
        buf = buf + m
        break if m.empty? || m.end_with?("\n")
      end

      parse(buf)
      @sock.close

    rescue Errno::ECONNRESET
      # pass
    end

    def parse(data)
      begin
        req = JSON.parse(data, :symbolize_names => true)

      rescue TypeError, JSON::ParserError
        return error("Syntax error")
      end

      log(:info, :user_control, "Received command '#{req[:cmd]}'")

      cmd = UserCommand.find(req[:cmd].to_sym)
      return error("Unsupported command '#{req[:cmd]}'") unless cmd

      output = {}

      begin
        ret = cmd.run(@user, req[:opts])

      rescue => err
        log(:warn, :user_control, "Error during command execution: #{err.message}")
        log(:warn, :user_control, err.backtrace.join("\n"))
        output[:error] = err.message
        error(output)

      else
        if ret[:status]
          ok(ret[:output])

        else
          error(ret[:message])
        end
      end
    end

    def error(err)
      send_data(status: false, message: err)
    end

    def ok(res)
      send_data(status: true, response: res)
    end

    def send_data(data)
      @sock.send(data.to_json + "\n", 0)

    rescue Errno::EPIPE
    end
  end
end
