require 'libosctl'

module OsCtl::Oomd
  class Killer
    include OsCtl::Lib::Utils::Log

    class Container
      attr_reader :pool, :id, :first_hit, :last_hit, :restart_hits, :stop_hits

      def initialize(pool, id)
        @pool = pool
        @id = id
        @restart_hits = 0
        @stop_hits = 0
      end

      def hit
        @restart_hits += 1
        @stop_hits += 1
        @first_hit ||= Time.now
        @last_hit = Time.now
      end

      def miss
        @restart_hits -= 1
        @restart_hits = 0 if @restart_hits < 0

        @stop_hits -= 1
        @stop_hits = 0 if @stop_hits < 0
      end

      def reset_restart_hits
        @restart_hits = 0
      end

      def reset_stop_hits
        @stop_hits = 0
      end
    end

    attr_reader :restart_hits, :stop_hits

    def initialize(restart_hits:, stop_hits:, dry_run:)
      @restart_hits = restart_hits
      @stop_hits = stop_hits
      @dry_run = dry_run
      @event_queue = OsCtl::Lib::Queue.new
      @prune_queue = OsCtl::Lib::Queue.new
      @mutex = Mutex.new
      @containers = {}
    end

    def start
      @event_thread = Thread.new { process_events }
      @prune_thread = Thread.new { prune }
    end

    def add_hit(pool, id)
      @event_queue << [:hit, pool, id]
    end

    def add_miss(pool, id)
      @event_queue << [:miss, pool, id]
    end

    def watched?(pool, id)
      @mutex.synchronize do
        ct = @containers["#{pool}:#{id}"]
        !ct.nil? && (ct.restart_hits > 0 || ct.stop_hits > 0)
      end
    end

    def export
      @mutex.synchronize do
        @containers.values.map(&:clone)
      end
    end

    def log_type
      'killer'
    end

    protected

    def process_events
      loop do
        event, pool, id = @event_queue.pop
        ctid = "#{pool}:#{id}"
        action = nil

        @mutex.synchronize do
          ct = @containers[ctid]
          ct = @containers[ctid] = Container.new(pool, id) if ct.nil?

          if event == :hit
            ct.hit
            action = determine_action(ct)
          else
            ct.miss
          end

          log(:info, "#{ctid} #{event}, #{ct.restart_hits}/#{@restart_hits} restart hits, #{ct.stop_hits}/#{@stop_hits} stop hits")
        end

        take_action(pool, id, action) if action
      end
    end

    def determine_action(ct)
      if ct.stop_hits >= @stop_hits
        :stop
      elsif ct.restart_hits >= @restart_hits
        :restart
      end
    end

    def take_action(pool, id, action)
      ctid = "#{pool}:#{id}"
      log(:info, "#{action} #{ctid}")
      now = Time.now
      reset_hits = @dry_run

      unless @dry_run
        if Kernel.system('osctl', 'ct', action.to_s, '--kill', ctid)
          reset_hits = true
          event = {
            events: [
              type: 'osctl_oomd',
              opts: {
                pool: pool,
                id: id,
                action: action,
                time: now.to_i
              }
            ]
          }

          r, w = IO.pipe
          pid = Process.spawn('osctl', 'event', 'broadcast', in: r, close_others: true)
          r.close
          w.puts(event.to_json)
          w.close
          Process.wait(pid)

          if $?.exitstatus != 0
            log(:warn, "osctl event broadcast exited with #{$?.exitstatus}")
          end
        else
          log(:warn, "osctl ct #{action} #{ctid} failed")
        end
      end

      return unless reset_hits

      @mutex.synchronize { @containers[ctid]&.send(:"reset_#{action}_hits") }
    end

    def prune
      loop do
        @prune_queue.pop(timeout: 60)

        @mutex.synchronize do
          t = Time.now

          @containers.delete_if do |_ctid, ct|
            ct.stop_hits == 0 && ct.restart_hits == 0 && ct.last_hit < Time.now - 300
          end
        end
      end
    end
  end
end
