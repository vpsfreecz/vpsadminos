module OsCtld
  class Eventd::Worker
    include Lockable

    def initialize
      init_lock
      @queue = Queue.new
      @subscribers = []
    end

    def start
      @thread = Thread.new { run_worker }
      nil
    end

    def stop
      if @thread
        @queue << :stop
        @thread.join
        @thread = nil
      end

      nil
    end

    # @param queue [OsCtl::Lib::Queue]
    def subscribe(queue)
      exclusively { @subscribers << queue }
      nil
    end

    # @param queue [OsCtl::Lib::Queue]
    def unsubscribe(queue)
      exclusively { @subscribers.delete(queue) }
      nil
    end

    # @return [Integer]
    def size
      inclusively { @subscribers.length }
    end

    # @param event [Eventd::Event]
    def report(event)
      @queue << event
    end

    protected

    def run_worker
      loop do
        event = @queue.pop
        break if event == :stop

        @subscribers.each do |queue|
          queue << event
        end
      end

      @subscribers.clear
    end
  end
end
