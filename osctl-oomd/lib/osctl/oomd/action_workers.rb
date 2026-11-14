require 'json'
require 'libosctl'
require 'osctl/client'

module OsCtl::Oomd
  # Fixed physical command slots. Only the controller grants work; a free slot
  # never pulls an older candidate from a backlog.
  class ActionWorkers
    include OsCtl::Lib::Utils::Log

    # The existing client treats a missing status as an error response. For
    # actions, malformed protocol must instead leave effects unknown.
    class ActionClient < OsCtl::Client
      def initialize(*)
        super
        @expect_version = true
      end

      def parse(raw)
        data = super
        valid = data.is_a?(Hash) && if @expect_version
                                      data[:version].is_a?(String)
                                    elsif data[:status] == false
                                      data[:message].is_a?(String) && !data.has_key?(:progress)
                                    elsif data[:status] == true
                                      if data.has_key?(:progress)
                                        data[:progress].is_a?(String) && !data.has_key?(:response)
                                      else
                                        data.has_key?(:response)
                                      end
                                    else
                                      false
                                    end
        raise OsCtl::Client::Error, 'invalid guarded action response' unless valid

        @expect_version = false
        data
      end
    end

    attr_reader :notification_drops, :notification_failures

    def initialize(size:, dry_run:, executor: nil, notifier: nil)
      @size = size
      @dry_run = dry_run
      @executor = executor || method(:execute)
      @notifier = notifier || method(:notify)
      @jobs = Array.new(size) { SizedQueue.new(1) }
      @busy = Array.new(size, false)
      @results = Queue.new
      @notifications = SizedQueue.new(16)
      @notification_drops = 0
      @notification_failures = 0
      @stopping = false
    end

    def start
      @notification_thread = Thread.new do
        loop do
          event = @notifications.pop
          break if event == :stop

          begin
            @notifier.call(event)
          rescue StandardError
            @notification_failures += 1
          end
        end
      end
      @threads = @jobs.each_with_index.map do |queue, slot|
        Thread.new do
          loop do
            permit = queue.pop
            break if permit == :stop

            begin
              result = @dry_run || @executor.call(permit)
              @results << [slot, permit, result ? :success : :failed]
            rescue StandardError
              # The command's effects may be unknown. The controller retains
              # this physical slot; no timeout/replacement can imply completion.
              @results << [slot, permit, :unknown]
              # Keep shutdown and ownership pending too; no evidence proves
              # that an interrupted command has stopped acting.
              Queue.new.pop
            end
          end
        end
      end
    end

    def dispatch(permit)
      return false if @stopping

      slot = @busy.index(false)
      return false unless slot

      @busy[slot] = true
      @jobs[slot] << permit
      true
    end

    def completions
      loop do
        slot, permit, status = @results.pop(true)
        @busy[slot] = false unless status == :unknown
        yield permit, status
      end
    rescue ThreadError
      nil
    end

    def publish(event)
      @notifications.push(event, true)
      true
    rescue ThreadError
      @notification_drops += 1
      false
    end

    def stop
      @stopping = true
      @jobs.each { |queue| queue << :stop }
      @threads&.each(&:join)
      @notifications << :stop
      @notification_thread&.join
    end

    protected

    def execute(permit)
      client = ActionClient.new
      client.open
      response = client.cmd_response(
        :"ct_oomd_#{permit.fetch(:action)}",
        pool: permit.fetch(:pool), id: permit.fetch(:id),
        expected_init_pid: permit.fetch(:run).fetch(0),
        expected_init_start_time: permit.fetch(:run).fetch(1),
        wait: 120
      ) do |message|
        # No stdout or logger call in the execution slot: even progress uses
        # the one bounded notification worker. Drops stay visible in metrics.
        publish(type: :log, level: :info,
                message: "#{permit.fetch(:pool)}:#{permit.fetch(:id)} #{message.byteslice(0, 256)}")
      end
      response.ok?
    ensure
      client&.close if client&.socket && !client.socket.closed?
    end

    def notify(event)
      if event[:type] == :log
        log(event.fetch(:level), event.fetch(:message))
        return
      end

      r, w = IO.pipe
      pid = Process.spawn('osctl', 'event', 'broadcast', in: r, close_others: true)
      r.close
      begin
        w.puts(JSON.generate(events: [event]))
      ensure
        w.close
        Process.wait(pid)
      end
      raise 'event broadcast failed' unless $?.success?
    ensure
      r&.close unless r&.closed?
      w&.close unless w&.closed?
    end
  end
end
