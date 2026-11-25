require 'json'

module OsCtl::Oomd
  # Independent bounded best-effort event delivery. It never reserves actions.
  class ExposureEvents
    def initialize(notifier: nil)
      @notifier = notifier || method(:notify)
      @queue = Queue.new
      @mutex = Mutex.new
      @parts = @bytes = @failures = 0
    end

    def start
      @thread = Thread.new do
        loop do
          item = @queue.pop
          break if item == :stop

          events, bytes = item
          events.each do |event|
            @notifier.call(event)
          rescue StandardError
            @mutex.synchronize { @failures += 1 }
            # Loss is exposed by sequence/part gaps. No durable retry promise.
          end
          @mutex.synchronize do
            @parts -= events.size
            @bytes -= bytes
          end
        end
      end
    end

    def publish(events)
      bytes = events.sum { |event| JSON.generate(event.fetch(:opts)).bytesize }
      @mutex.synchronize do
        return false if @parts + events.size > 64 || @bytes + bytes > 1024 * 1024

        @parts += events.size
        @bytes += bytes
        @queue << [events, bytes]
      end
      true
    end

    def status
      @mutex.synchronize { { rtnl_exposure_pending_parts: @parts, rtnl_exposure_event_failures: @failures } }
    end

    def stop
      @queue << :stop
      @thread&.join
    end

    protected

    def notify(event)
      OsCtl::Client.new.tap do |client|
        client.open
        client.cmd_data!(:event_broadcast, events: [event])
      ensure
        client.close
      end
    end
  end
end
