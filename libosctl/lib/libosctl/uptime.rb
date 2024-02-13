module OsCtl::Lib
  # Read `/proc/uptime`
  class Uptime
    # @return [Float] uptime in seconds
    attr_reader :uptime

    # @return [Float] idle time in seconds
    attr_reader :idle_time

    # @return [Time] time of boot
    attr_reader :booted_at

    def initialize(path: '/proc/uptime')
      parse(path)
    end

    protected

    def parse(path)
      values = File.read(path).strip.split

      @uptime = values[0].to_f
      @idle_time = values[1].to_f
      @booted_at = Time.now - @uptime
    end
  end
end
