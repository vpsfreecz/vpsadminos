module OsCtl::Lib
  # Read system load average from /proc/loadavg, see man proc(5)
  class LoadAvg
    # @return [Hash<1, 5, 15>] load averages
    attr_reader :avg

    # @return [Integer]
    attr_reader :runnable

    # @return [Integer]
    attr_reader :total

    # @return [Integer]
    attr_reader :last_pid

    # @param path [String] path to /proc/loadavg
    def initialize(path: '/proc/loadavg')
      parse(path)
    end

    def to_a
      [
        @avg[1],
        @avg[5],
        @avg[15],
      ]
    end

    protected
    def parse(path)
      parsed = File.read(path).strip.split(' ')

      @avg = {
        1 => parsed[0].to_f,
        5 => parsed[1].to_f,
        15 => parsed[2].to_f,
      }

      runnable, total = parsed[3].split('/')
      @runnable = runnable.to_i
      @total = total.to_i

      @last_pid = parsed[4].to_i
    end
  end
end
