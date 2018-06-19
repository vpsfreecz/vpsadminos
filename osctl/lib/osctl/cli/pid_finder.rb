require 'libosctl'

module OsCtl::Cli
  class PidFinder
    def initialize(header: true)
      print('PID', 'CONTAINER', 'CTPID', 'NAME') if header
    end

    def find(pid)
      f = File.open(File.join('/proc', pid, 'cgroup'), 'r')
      line = f.readline
      f.close

      _id, _subsys, path = line.split(':')

      if /^\/osctl\/pool\.([^\/]+)/ !~ path
        on_host(pid)
        return
      end

      pool = $1

      if /ct\.([^\/]+)\/user\-owned\// !~ path
        not_found(pid)
        return
      end

      ct = $1
      in_ct(pid, pool, ct)

    rescue Errno::ENOENT
      not_found(pid)
    end

    protected
    def on_host(pid)
      print(pid, '[host]')
    end

    def in_ct(pid, pool, ctid)
      process = OsCtl::Lib::OsProcess.new(pid)
      print(pid, "#{pool}:#{ctid}", process.ctpid, process.name)

    rescue Errno::ENOENT
      print(pid, "#{pool}:#{ctid}")
    end

    def not_found(pid)
      print(pid, '-')
    end

    def print(pid, ct, ctpid = '-', name = '-')
      puts sprintf('%-10s %-20s %-10s %s', pid, ct, ctpid.to_s, name)
    end
  end
end
