require 'libosctl'

module OsCtl::Oomd
  class Watcher
    include OsCtl::Lib::Utils::Log

    def self.run(*, **)
      new(*, **).run
    end

    def initialize(interval:, cpu_percent:, memory_percent:, load_multiplier:, load_top:, restart_hits:, stop_hits:, export_file:, dry_run: false, verbose: false, rtnl_watchdog: nil)
      @interval = interval
      @cpu_percent = cpu_percent
      @memory_percent = memory_percent
      @load_multiplier = load_multiplier
      @load_top = load_top
      @dry_run = dry_run
      @verbose = verbose
      @host_load = HostLoad.new(@interval)
      @rtnl_watchdog = Controller.settings(rtnl_watchdog)
      @killer = if @rtnl_watchdog.fetch('enable')
                  Controller.new(interval:, cpu_percent:, memory_percent:, load_multiplier:, load_top:,
                                 restart_hits:, stop_hits:, rtnl_watchdog: @rtnl_watchdog, dry_run:, host_load: @host_load)
                else
                  Killer.new(restart_hits:, stop_hits:, dry_run:)
                end
      @exporter = Exporter.new(file: export_file, killer: @killer)
      @queue = OsCtl::Lib::Queue.new
    end

    def run
      return run_watchdog if @rtnl_watchdog.fetch('enable')

      @killer.start
      @exporter.start

      @ct_top = Thread.new do
        CtTop.run(@interval) do |data|
          @queue << data
        end
      end

      loop do
        data = @queue.pop

        lavg = data['loadavg'][0]
        @host_load << lavg

        median = @host_load.median
        threshold = median * @load_multiplier

        if @verbose
          log(:debug, "Load=#{lavg}, median=#{median}, threshold=#{threshold}")
          log(:debug, lavg < threshold ? 'OOMd inactive' : 'OOMd active')
        end

        next if lavg < threshold

        cts_by_lavg = data['containers'].sort do |a, b|
          b['loadavg'][0] <=> a['loadavg'][0]
        end

        data['containers'].each do |ct|
          have_hit = hit?(ct, cts_by_lavg)

          if have_hit
            @killer.add_hit(ct['pool'], ct['id'])
          elsif @killer.watched?(ct['pool'], ct['id'])
            @killer.add_miss(ct['pool'], ct['id'])
          end
        end
      end
    end

    def run_watchdog
      @killer.start
      @exporter.start
      latest_mutex = Mutex.new
      latest = nil
      stopping = false
      previous_term = Signal.trap('TERM') { stopping = true }
      previous_int = Signal.trap('INT') { stopping = true }
      @ct_top = Thread.new do
        CtTop.run(@interval, oomd: true) do |data|
          latest_mutex.synchronize { latest = data }
        end
      end
      until stopping
        data = latest_mutex.synchronize do
          value = latest
          latest = nil
          value
        end
        if data
          @killer.observe(data)
        else
          @killer.tick
        end
        sleep(0.25)
      end
    ensure
      @killer.stop
      @exporter.stop
      Signal.trap('TERM', previous_term) if previous_term
      Signal.trap('INT', previous_int) if previous_int
    end

    def hit?(ct, cts_by_lavg)
      Eligibility.hit?(ct, cts_by_lavg, memory_percent: @memory_percent, cpu_percent: @cpu_percent, load_top: @load_top)
    end

    def log_type
      'watcher'
    end
  end
end
