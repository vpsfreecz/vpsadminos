require 'ipaddress'

module OsCtl::Cli
  class Container < Command
    def list
      osctld_fmt(:ct_list)
    end

    def create
      raise "missing argument" unless args[0]

      osctld_fmt(
        :ct_create,
        id: args[0],
        user: opts[:user],
        template: File.absolute_path(opts[:template]),
        route_via: parse_route_via,
      )
    end

    def delete
      raise "missing argument" unless args[0]

      osctld_fmt(:ct_delete, id: args[0])
    end

    def start
      raise "missing argument" unless args[0]

      osctld_fmt(:ct_start, id: args[0])
    end

    def stop
      raise "missing argument" unless args[0]

      osctld_fmt(:ct_stop, id: args[0])
    end

    def restart
      raise "missing argument" unless args[0]

      osctld_fmt(:ct_restart, id: args[0])
    end

    def console
      raise "missing argument" unless args[0]

      ret = osctld(:ct_console, id: args[0], tty: opts[:tty])

      unless ret[:status]
        warn "Error: #{ret[:message]}"
        return
      end

      cmd = ret[:response]

      pid = Process.fork do
        cmd[:env].each do |k, v|
          ENV[k.to_s] = v
        end

        Process.exec(*cmd[:cmd])
      end

      Process.wait(pid)
    end

    def attach
      raise "missing argument" unless args[0]

      ret = osctld(:ct_attach, id: args[0])

      unless ret[:status]
        warn "Error: #{ret[:message]}"
        return
      end

      cmd = ret[:response]

      pid = Process.fork do
        cmd[:env].each do |k, v|
          ENV[k.to_s] = v
        end

        Process.exec(*cmd[:cmd])
      end

      Process.wait(pid)
    end

    def exec
      raise "missing argument" unless args[0]
      raise "missing command to execute" if args.count < 2

      c = osctld_open
      c.cmd(:ct_exec, id: args[0], cmd: args[1..-1])
      ret = c.reply

      if !ret[:status] || ret[:response] != 'continue'
        warn "exec not available: #{ret[:message]}"
        exit(false)
      end

      r_in, w_in = IO.pipe
      r_out, w_out = IO.pipe
      r_err, w_err = IO.pipe

      c.send_io(r_in)
      c.send_io(w_out)
      c.send_io(w_err)

      r_in.close
      w_out.close
      w_err.close

      loop do
        rs, ws, = IO.select([STDIN, r_out, r_err, c.socket])

        rs.each do |r|
          case r
          when r_out
            data = r.read_nonblock(4096)
            STDOUT.write(data)
            STDOUT.flush

          when r_err
            data = r.read_nonblock(4096)
            STDERR.write(data)
            STDERR.flush

          when STDIN
            data = r.read_nonblock(4096)
            w_in.write(data)

          when c.socket
            r_out.close
            r_err.close

            c.reply
            return
          end
        end
      end
    end

    def su
      raise "missing argument" unless args[0]

      # TODO: error handling
      cmd = osctld(:ct_su, id: args[0])[:response]
      pid = Process.fork do
        cmd[:env].each do |k, v|
          ENV[k.to_s] = v
        end

        Process.exec(*cmd[:cmd])
      end

      Process.wait(pid)
    end

    def set
      raise "missing argument" unless args[0]
      params = {id: args[0]}

      rv = parse_route_via
      params[:route_via] = rv unless rv.empty?

      raise "nothing to do" if params.empty?

      osctld_fmt(:ct_set, params)
    end

    def ip_list
      raise 'missing container id' unless args[0]
      osctld_fmt(:ct_ip_list, id: args[0])
    end

    def ip_add
      raise 'missing container id' unless args[0]
      raise 'missing addr' unless args[1]
      osctld_fmt(:ct_ip_add, id: args[0], addr: args[1])
    end

    def ip_del
      raise 'missing container id' unless args[0]
      raise 'missing addr' unless args[1]
      osctld_fmt(:ct_ip_del, id: args[0], addr: args[1])
    end

    protected
    def parse_route_via
      ret = {}

      opts['route-via'].each do |net|
        addr = IPAddress.parse(net)
        ip_v = addr.ipv4? ? 4 : 6

        if ret.has_key?(ip_v)
          fail "network for IPv#{ip_v} has already been set to route via #{ret[ip_v]}"
        end

        case ip_v
        when 4
          if addr.prefix > 30
            fail "cannot route via IPv4 network smaller than /30"
          end

        when 6
          # TODO: check?
        end

        ret[ip_v] = addr.to_string
      end

      ret
    end
  end
end
