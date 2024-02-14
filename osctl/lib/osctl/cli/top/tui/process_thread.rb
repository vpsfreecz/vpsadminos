require 'libosctl'

module OsCtl::Cli::Top
  class Tui::ProcessThread
    def initialize(rate)
      @rate = rate
      @stats = empty_stats
      @last_probe = nil
      @queue = OsCtl::Lib::Queue.new
      @mutex = Mutex.new
    end

    def start
      @stop = false
      @thread = Thread.new { work }
    end

    def stop
      return unless @thread

      @stop = true
      @queue << :stop
      @thread.join
      @thread = nil
    end

    def get_stats
      @mutex.synchronize do
        [@stats, @last_probe]
      end
    end

    protected

    def work
      probe_processes

      loop do
        cmd = @queue.pop(timeout: @rate)
        return if cmd == :stop

        probe_processes
      end
    end

    def probe_processes
      new_stats = empty_stats
      cnt = 0

      OsCtl::Lib::ProcessList.each(parse_status: false) do |p|
        break if @stop

        st = p.state

        cnt += 1
        new_stats[st] += 1 if new_stats.has_key?(st)
      end

      return if @stop

      new_stats['TOTAL'] = cnt

      @mutex.synchronize do
        @stats = new_stats
        @last_probe = Time.now
      end
    end

    def empty_stats
      {
        'TOTAL' => 0,
        'R' => 0,
        'S' => 0,
        'D' => 0,
        'Z' => 0,
        'T' => 0,
        't' => 0,
        'X' => 0
      }
    end
  end
end
