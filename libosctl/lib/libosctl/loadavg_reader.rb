module OsCtl::Lib
  # Reads and parses per-container load averages from LXCFS
  class LoadAvgReader
    FILE = 'proc/.loadavgs'

    LoadAvg = Struct.new(:pool_name, :ctid, :avg, :runnable, :total, :last_pid) do
      def ident
        "#{pool_name}:#{ctid}"
      end

      def averages
        [avg[1], avg[5], avg[15]]
      end
    end

    # Read loadavgs for given containers and return them in a hash indexed by ctid
    # @param containers [Array<Hash>] list of containers as received from osctld
    # @return [Hash<String, LoadAvg>]
    def self.read_for(containers)
      reader = new
      lavgs = {}

      lxcfs_workers = {}

      containers.each do |ct|
        mountpoint = ct[:lxcfs_mountpoint]
        next if mountpoint.nil?

        k = "#{ct[:pool]}:#{ct[:id]}"

        lxcfs_workers[mountpoint] ||= {}
        lxcfs_workers[mountpoint][k] = true
      end

      lxcfs_workers.each do |mountpoint, cts|
        reader.read_lxcfs(mountpoint) do |lavg|
          lavgs[ lavg.ident ] = lavg if cts.has_key?(lavg.ident)
        end
      end

      ret = {}

      containers.each do |ct|
        k = "#{ct[:pool]}:#{ct[:id]}"

        ret[k] = lavgs[k] if lavgs.has_key?(k)
      end

      ret
    end

    # Read load averages from LXCFS
    # @param mountpoint [String]
    # @yieldparam lavg [LoadAvg]
    # @yieldreturn [:stop, any]
    def read_lxcfs(mountpoint)
      File.open(File.join(mountpoint, FILE), 'r') do |f|
        f.each_line do |line|
          lavg = parse(line)
          next if lavg.nil?
          break if yield(lavg) == :stop
        end
      end

    rescue Errno::ENOENT
    end

    protected
    def parse(line)
      # <cgroup> <avg1> <avg5> <avg15> <runnable>/<total> <last_pid>
      cols = line.strip.split
      return if cols.size != 6

      pool, ctid = parse_ct(cols[0])
      return if pool.nil?

      runnable, total = cols[4].split('/').map(&:to_i)

      LoadAvg.new(
        pool,
        ctid,
        {1 => cols[1].to_f, 5 => cols[2].to_f, 15 => cols[3].to_f},
        runnable,
        total,
        cols[5].to_i
      )
    end

    def parse_ct(cgroup)
      return if /^\/osctl\/pool\.([^\/]+)/ !~ cgroup
      pool = $1

      return if /ct\.([^\/]+)\/user\-owned\// !~ cgroup
      ct = $1

      [pool, ct]
    end
  end
end
