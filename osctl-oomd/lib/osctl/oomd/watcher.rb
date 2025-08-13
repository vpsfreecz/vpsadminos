require 'libosctl'

module OsCtl::Oomd
  class Watcher
    include OsCtl::Lib::Utils::Log

    def self.run(*, **)
      new(*, **).run
    end

    def initialize(interval:, cpu_percent:, memory_percent:, load_multiplier:, load_top:, restart_hits:, stop_hits:, export_file:, dry_run: false, verbose: false)
      @interval = interval
      @cpu_percent = cpu_percent
      @memory_percent = memory_percent
      @load_multiplier = load_multiplier
      @load_top = load_top
      @dry_run = dry_run
      @verbose = verbose
      @host_load = HostLoad.new(@interval)
      @killer = Killer.new(restart_hits:, stop_hits:, dry_run:)
      @exporter = Exporter.new(file: export_file, killer: @killer)
      @queue = OsCtl::Lib::Queue.new
    end

    def run
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
        threshold = @host_load.median * @load_multiplier

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

    def hit?(ct, cts_by_lavg)
      return false if ct['memory_limit'].nil?

      memory_pct = ct['memory'].to_f / ct['memory_limit'] * 100
      return false if memory_pct < @memory_percent

      if ct['cpu_limit']
        cpu_pct = ct['cpu_usage'] / ct['cpu_limit'] * 100
        return false if cpu_pct < @cpu_percent
      end

      load_pos = cts_by_lavg.index do |other_ct|
        other_ct['pool'] == ct['pool'] && other_ct['id'] == ct['id']
      end

      return false if load_pos.nil? || load_pos >= @load_top

      true
    end

    def log_type
      'watcher'
    end
  end
end
