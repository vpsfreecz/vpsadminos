module OsCtl::Cli
  class Top::ArcStats
    def initialize(file = '/proc/spl/kstat/zfs/arcstats')
      parse(file)
    end

    # @param since [ArcStats, nil]
    def hit_rate(since = nil)
      hits = since ? @data[:hits] - since.hits : @data[:hits]
      misses = since ? @data[:misses] - since.misses : @data[:misses]

      sum = hits + misses
      return 0.0 if sum == 0

      hits.to_f / sum * 100
    end

    # @param since [ArcStats, nil]
    def l2_hit_rate(since = nil)
      hits = since ? @data[:l2_hits] - since.l2_hits : @data[:l2_hits]
      misses = since ? @data[:l2_misses] - since.l2_misses : @data[:l2_misses]

      sum = hits + misses
      return 0.0 if sum == 0

      hits.to_f / sum * 100
    end

    def method_missing(name, *args, **kwargs)
      if @data.has_key?(name) && args.size <= 1
        return @data[name] - args[0].send(name) if args[0]

        return @data[name]

      end

      super(name, *args, **kwargs)
    end

    protected

    def parse(file)
      @data = {}

      File.readlines(file)[2..-1].each do |line|
        name, type, value = line.split

        @data[name.to_sym] = value.to_i
      end
    end
  end
end
