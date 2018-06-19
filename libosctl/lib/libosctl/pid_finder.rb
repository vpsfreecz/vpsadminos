module OsCtl::Lib
  # Locate containers by process IDs from the host
  class PidFinder
    Result = Struct.new(:pool, :ctid, :os_process)

    # @param pid [Integer] process ID from the host
    # @return [Result, nil]
    def find(pid)
      os_proc = OsProcess.new(pid)
      f = File.open(File.join('/proc', pid.to_s, 'cgroup'), 'r')
      line = f.readline
      f.close

      _id, _subsys, path = line.split(':')

      if /^\/osctl\/pool\.([^\/]+)/ !~ path
        return Result.new(nil, :host, os_proc)
      end

      pool = $1

      return if /ct\.([^\/]+)\/user\-owned\// !~ path

      ctid = $1
      Result.new(pool, ctid, os_proc)

    rescue Errno::ENOENT
      nil
    end
  end
end
