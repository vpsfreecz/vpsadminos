module OsCtl::Cli
  class Top::ArcStats
    def initialize(file = '/proc/spl/kstat/zfs/arcstats')
      parse(file)
    end

    def hit_rate
      sum = @data[:hits] + @data[:misses]
      @data[:hits].to_f / sum * 100
    end

    def method_missing(name, *args)
      return @data[name] if @data.has_key?(name) && args.empty?
      super(name, *args)
    end

    protected
    def parse(file)
      @data = {}

      File.readlines(file)[2..-1].each do |line|
        name, type, value = line.split

        @data[ name.to_sym ] = value.to_i
      end
    end
  end
end
