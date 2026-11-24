require 'json'
require 'libosctl'
require 'osctl/client'
require 'osctl/oomd/evidence'

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

    attr_reader :notification_failures, :evidence

    def notification_drops = 0

    def initialize(size:, dry_run:, executor: nil, notifier: nil, evidence: nil)
      @size = size
      @dry_run = dry_run
      @executor = executor || method(:execute)
      @notifier = notifier || method(:notify)
      @jobs = Array.new(size) { SizedQueue.new(1) }
      @busy = Array.new(size, false)
      @results = Queue.new
      @evidence = evidence || Evidence.new
      @notifications = Queue.new
      @broadcast_mutex = Mutex.new
      @broadcast_used = 0
      @notification_failures = 0
      @stopping = false
    end

    def start
      @evidence.start
      @notification_thread = Thread.new do
        loop do
          event = @notifications.pop
          break if event == :stop

          loop do
            @notifier.call(event)
            @broadcast_mutex.synchronize { @broadcast_used -= 1 }
            break
          rescue StandardError
            @notification_failures += 1
            sleep(0.25) # Retain and retry this same ID; never re-execute work.
          end
        end
      end
      @threads = @jobs.each_with_index.map do |queue, slot|
        Thread.new do
          loop do
            permit = queue.pop
            break if permit == :stop

            begin
              result = if @dry_run
                         :simulated
                       else
                         @executor.call(permit) ? :success : :failed
                       end
              @results << [slot, permit, result]
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

    def available?
      !@stopping && @busy.include?(false) && @broadcast_mutex.synchronize { @broadcast_used < 2 }
    end

    def dispatch(permit)
      return false if @stopping

      slot = @busy.index(false)
      return false unless slot

      permit[:action_id] ||= SecureRandom.hex(16)
      fields = permit.except(:evidence_ticket, :broadcast_reserved)
      admission = @evidence.frame('action_admitted', fields.merge(message: "guarded admission #{permit[:action]} #{permit[:pool]}:#{permit[:id]}"))
      dispatched = @evidence.frame('action_dispatched', fields.merge(message: "guarded dispatch #{permit[:action]} #{permit[:pool]}:#{permit[:id]}"))
      terminal = @evidence.frame('action_result', fields.merge(result: :simulated, message: "would #{permit[:action]} #{permit[:pool]}:#{permit[:id]} result=simulated"))
      ticket = @evidence.reserve(admission.size + dispatched.size + terminal.size)
      return false unless ticket

      reserved = @broadcast_mutex.synchronize do
        next false if @broadcast_used >= 2

        @broadcast_used += 1
        true
      end
      unless reserved
        @evidence.release(ticket)
        return false
      end
      if block_given? && !yield
        @evidence.release(ticket)
        @broadcast_mutex.synchronize { @broadcast_used -= 1 }
        return false
      end
      permit[:evidence_ticket] = ticket
      permit[:broadcast_reserved] = true
      @evidence.batch(admission + dispatched, split_ticket(ticket, admission.size + dispatched.size))
      @busy[slot] = true
      @jobs[slot] << permit
      true
    end

    def completions
      loop do
        slot, permit, status = @results.pop(true)
        @busy[slot] = false unless status == :unknown
        fields = permit.except(:evidence_ticket, :broadcast_reserved)
        label = status == :simulated ? "would #{permit[:action]}" : permit[:action]
        @evidence.batch(@evidence.frame('action_result', fields.merge(result: status, message: "#{label} #{permit[:pool]}:#{permit[:id]} result=#{status}")), permit.fetch(:evidence_ticket))
        if status == :success
          publish_success(type: 'osctl_oomd', event_id: permit[:action_id], action_id: permit[:action_id],
                          opts: { pool: permit[:pool], id: permit[:id], action: permit[:action], time: permit[:time] })
        else
          @broadcast_mutex.synchronize { @broadcast_used -= 1 }
        end
        yield permit, status
      end
    rescue ThreadError
      nil
    end

    def stop
      @stopping = true
      @jobs.each { |queue| queue << :stop }
      while @busy.any?
        completions { |permit, status| yield permit, status if block_given? }
        sleep(0.01) if @busy.any?
      end
      @threads&.each(&:join)
      @notifications << :stop
      @notification_thread&.join
      @evidence.stop
    end

    protected

    # Success records already own one of two slots, including in-flight writes.
    def publish_success(event)
      @notifications << event
      true
    end

    # Split unused reservation without altering total payload accounting.
    def split_ticket(ticket, count)
      ticket[0] -= count
      ticket[1] -= count * Evidence::LINE_BYTES
      [count, count * Evidence::LINE_BYTES]
    end

    def execute(permit)
      permit[:action_id] ||= SecureRandom.hex(16)
      client = ActionClient.new
      client.open
      response = client.cmd_response(
        :"ct_oomd_#{permit.fetch(:action)}",
        pool: permit.fetch(:pool), id: permit.fetch(:id),
        expected_init_pid: permit.fetch(:run).fetch(0),
        expected_init_start_time: permit.fetch(:run).fetch(1),
        wait: 120
      ) do |message|
        bytes = message
        parts = [(bytes.bytesize / 1440.0).ceil, 1].max
        progress_id = SecureRandom.hex(16)
        parts.times do |part|
          record = @evidence.frame('action_progress', action_id: permit[:action_id], progress_id:,
                                                      part: part + 1, parts:, original_bytes: bytes.bytesize,
                                                      encoding: 'base64', data: Base64.strict_encode64(bytes.byteslice(part * 1440, 1440) || ''))
          ticket = @evidence.reserve(record.size, wait: true)
          @evidence.batch(record, ticket)
        end
      end
      response.ok?
    ensure
      client&.close if client&.socket && !client.socket.closed?
    end

    def notify(event)
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
