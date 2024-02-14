module OsCtl::Lib
  # Returns per-container load averages
  class LoadAvgReader
    # This file contains a list of load averages from first-level cgroup namespaces
    #
    # Available only on vpsAdminOS
    FILE = '/proc/vpsadminos/loadavg'.freeze

    LoadAvg = Struct.new(:pool_name, :ctid, :avg, :runnable, :total) do
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

      reader.read(containers) do |lavg|
        lavgs[lavg.ident] = lavg
      end

      lavgs
    end

    # Read container load averages
    # @param containers [Array<Hash>] list of containers as received from osctld
    # @yieldparam lavg [LoadAvg]
    # @yieldreturn [:stop, any]
    def read(containers)
      cgns_ids = get_cgroup_ns_ids(containers)

      File.open(FILE, 'r') do |f|
        f.each_line do |line|
          lavg = parse(line, cgns_ids)
          next if lavg.nil?
          break if yield(lavg) == :stop
        end
      end

      nil
    rescue Errno::ENOENT
    end

    protected

    def get_cgroup_ns_ids(containers)
      ret = {}

      containers.each do |ct|
        next if ct[:init_pid].nil?

        begin
          ptr = File.readlink(File.join('/proc', ct[:init_pid].to_s, 'ns/cgroup'))
        rescue Errno::ENOENT
          next
        end

        next if /^cgroup:\[(\d+)\]$/ !~ ptr

        cg_id = ::Regexp.last_match(1)
        ret[cg_id] = ct
      end

      ret
    end

    def parse(line, cgns_ids)
      # <cgns id> <avg1> <avg5> <avg15> <runnable>/<total>
      cols = line.strip.split
      return if cols.size != 5

      ct = cgns_ids[cols[0]]
      return if ct.nil?

      runnable, total = cols[4].split('/')

      LoadAvg.new(
        ct[:pool],
        ct[:id],
        { 1 => cols[1].to_f, 5 => cols[2].to_f, 15 => cols[3].to_f },
        runnable.to_i,
        total.to_i
      )
    end
  end
end
