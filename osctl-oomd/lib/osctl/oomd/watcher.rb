require 'libosctl'

module OsCtl::Oomd
  class Watcher
    def self.run(*, **)
      new(*, **).run
    end

    def initialize(interval:, cpu_percent:, memory_percent:, load_multiplier:, load_top:, restart_after_seconds:, stop_after_seconds:,
                   export_file:, load_enable: true, restart_unknown_expiry_seconds: 30, dry_run: false, verbose: false, rtnl_watchdog: nil, rtnl_exposure: nil)
      @interval = interval
      @controller = Controller.new(interval:, cpu_percent:, memory_percent:, load_multiplier:, load_top:,
                                   restart_after_seconds:, stop_after_seconds:, load_enable:, restart_unknown_expiry_seconds:,
                                   rtnl_watchdog:, rtnl_exposure:, dry_run:, verbose:)
      @exporter = Exporter.new(file: export_file, killer: @controller)
    end

    # Keep a boundary and a cut with the latest observation. Neither a cut
    # nor an unvalidated overwritten observation can disappear by coalescing.
    class Mailbox
      def initialize
        @mutex = Mutex.new
      end

      def push(item)
        @mutex.synchronize do
          if @latest && [:child_started, {}].include?(item)
            omit_latest
          end
          case item
          when :child_started
            @new_child = true
            @broken = false
            @latest = nil
          when {}
            @broken = true
            @latest = nil
          else
            if @latest && !@latest.eql?(item)
              @broken = true
              omit_latest
            end
            @latest = item
          end
        end
      end

      def omit_latest
        @omitted_first ||= @latest['sequence']
        @omitted_first_epoch ||= @latest['epoch']
        @omitted_last = @latest['sequence']
        @omitted_last_epoch = @latest['epoch']
        @omitted_count = (@omitted_count || 0) + 1
      end

      def drain(controller, **)
        new_child, broken, data, gap = @mutex.synchronize do
          current = [@new_child, @broken, @latest, { first: @omitted_first, last: @omitted_last, count: @omitted_count || 0, first_epoch: @omitted_first_epoch, last_epoch: @omitted_last_epoch }]
          @new_child = @broken = @latest = @omitted_first = @omitted_last = @omitted_count = nil
          @omitted_first_epoch = @omitted_last_epoch = nil
          current
        end
        controller.mailbox_gap(**gap) if new_child && !broken && gap[:count] > 0
        controller.child_started if new_child
        if broken
          controller.mailbox_gap(**gap)
        end
        return controller.observe(data, **) if data

        controller.tick(**)
      end
    end

    def run
      @controller.start
      @exporter.start
      mailbox = Mailbox.new
      stopping = false
      previous_term = Signal.trap('TERM') { stopping = true }
      previous_int = Signal.trap('INT') { stopping = true }
      @ct_top = Thread.new do
        CtTop.run(@interval) { |item| mailbox.push(item) }
      end
      until stopping
        mailbox.drain(@controller)
        sleep(0.25)
      end
    ensure
      @controller.stop
      @exporter.stop
      Signal.trap('TERM', previous_term) if previous_term
      Signal.trap('INT', previous_int) if previous_int
    end
  end
end
