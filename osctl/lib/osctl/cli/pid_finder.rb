module OsCtl::Cli
  class PidFinder
    def initialize(header: true)
      print('PID', 'CONTAINER') if header
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

      print(pid, "#{pool}:#{ct}")

    rescue Errno::ENOENT
      not_found(pid)
    end

    protected
    def on_host(pid)
      print(pid, '[host]')
    end

    def not_found(pid)
      print(pid, '-')
    end

    def print(pid, ct)
      puts sprintf('%-10s %s', pid, ct)
    end
  end
end
