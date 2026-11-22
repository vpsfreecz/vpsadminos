module OsCtl::Lib
  class NetifStats
    def initialize
      @cache = {}
      @verified = {}
    end

    def reset
      @verified.clear
      cache.clear
    end

    # @param netif [String]
    def get_stats_for(netif)
      @cache[netif] ||= {
        tx: {
          bytes: read_stat(netif, :tx, :bytes),
          packets: read_stat(netif, :tx, :packets)
        },
        rx: {
          bytes: read_stat(netif, :rx, :bytes),
          packets: read_stat(netif, :rx, :packets)
        }
      }
    end

    def verified_stats(netif)
      return @verified[netif] if @verified.has_key?(netif)

      path = File.join('/sys/class/net', netif)
      File.open(path) do |dir|
        source = [dir.stat.dev, dir.stat.ino]
        stats = %i[tx rx].to_h do |direction|
          per_direction = %i[bytes packets].to_h do |kind|
            file = "/proc/self/fd/#{dir.fileno}/statistics/#{direction}_#{kind}"
            [kind, Integer(File.read(file).strip, 10)]
          end
          [direction, per_direction]
        end
        @verified[netif] = [source, stats]
      end
    rescue SystemCallError, IOError, ArgumentError
      @verified[netif] = nil
    end

    def get_stats_for_all
      ret = {}

      list_netifs.each do |netif|
        ret[netif] = get_stats_for(netif)
      end

      ret
    end

    # @param netifs [Array<String>]
    def cache_stats_for_interfaces(netifs)
      netifs.each do |netif|
        get_stats_for(netif)
      end
    end

    def list_netifs
      Dir.entries('/sys/class/net').select do |v|
        v != '.' && v != '..' && /^(lo|bond\d+|face|.+\.\d+)$/ !~ v
      end
    end

    # Read cached stats
    # @param netif [String]
    def [](netif)
      @cache[netif]
    end

    protected

    attr_reader :cache

    def read_stat(netif, dir, type)
      ret = File.read("/sys/class/net/#{netif}/statistics/#{dir}_#{type}")
      ret.strip.to_i
    rescue SystemCallError
      0
    end
  end
end
