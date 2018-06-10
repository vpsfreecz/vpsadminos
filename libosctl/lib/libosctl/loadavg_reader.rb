module OsCtl::Lib
  # Reads and parses per-container load averages from
  # `/var/lib/lxcfs/proc/.loadavgs`
  class LoadAvgReader
    FILE = '/var/lib/lxcfs/proc/.loadavgs'

    LoadAvg = Struct.new(:pool_name, :ctid, :avg, :runnable, :total, :last_pid) do
      def ident
        "#{pool_name}:#{ctid}"
      end

      def averages
        [avg[1], avg[5], avg[15]]
      end
    end

    # Read loadavgs for all containers
    # @return [Array<LoadAvg>]
    def self.read_all
      reader = new
      ret = reader.read.to_a
      reader.close
      ret
    end

    # Read loadavgs for all containers and return as a hash
    # @return [Hash<String, LoadAvg>]
    def self.read_all_hash
      reader = new
      ret = {}

      reader.read.each do |lavg|
        ret[ lavg.ident ] = lavg
      end

      reader.close
      ret
    end

    # Read loadavgs for selected containers
    # @param ctids [Array<String>] container ids with pool, i.e. `<pool>:<ctid>`
    # @return [Array<LoadAvg>]
    def self.read_for(ctids)
      reader = new
      ret = []

      reader.read.each do |lavg|
        if ctids.include?(lavg.ident)
          ret << lavg
          ctids.delete(lavg.ident)
        end

        break if ctids.empty?
      end

      reader.close
      ret
    end

    def initialize
      @fh = File.open(FILE, 'r')
    end

    # @return [Enumerator]
    def read
      @fh.each_line.lazy.map { |line| parse(line) }.reject { |v| v.nil? }
    end

    def close
      @fh.close
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
