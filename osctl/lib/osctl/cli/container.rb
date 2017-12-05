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
