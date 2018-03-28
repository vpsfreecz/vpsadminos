require 'concurrent'
require 'thread'

module OsCtld
  class AutoStart::Plan
    include OsCtl::Lib::Utils::Log

    attr_reader :pool

    def initialize(pool)
      @pool = pool
      @queue = Concurrent::Array.new
      @mutex = Mutex.new
    end

    def generate
      cts = DB::Containers.get.select { |ct| ct.pool == pool && ct.autostart }
      cts.sort! { |a, b| a.autostart <=> b.autostart }
      cts.each do |ct|
        queue << Item.new(ct.id, ct.autostart.priority, ct.autostart.delay)
      end
    end

    def start
      fail 'autostart already in progress' if running?

      t = Thread.new do
        log(:info, pool, 'Auto-starting containers')

        while queue.any?
          it = queue.shift
          break if it.nil?

          ct = DB::Containers.find(it.id, pool)
          next if ct.nil? || ct.running?

          log(:info, ct, 'Auto-starting container')
          Commands::Container::Start.run(pool: ct.pool.name, id: ct.id)

          sleep(it.delay)
        end

        log(:info, pool, 'Auto-starting containers finished')
      end

      sync { @thread = t }
    end

    def stop
      queue.clear
      sync do
        next unless @thread
        @thread.join
        @thread = nil
      end
    end

    def running?
      sync { @thread && @thread.alive? }
    end

    def get_queue
      queue.to_a
    end

    protected
    Item = Struct.new(:id, :priority, :delay)

    attr_reader :queue

    def sync
      @mutex.synchronize { yield }
    end
  end
end
