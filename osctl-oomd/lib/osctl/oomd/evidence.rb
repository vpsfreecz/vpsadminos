require 'base64'
require 'json'
require 'securerandom'

module OsCtl::Oomd
  # Payload accounting includes staging reservations and the writer-owned head.
  # Only complete local stdout writes release space; remote delivery is separate.
  class Evidence
    LINE_BYTES = 3072
    RECORDS = 512
    BYTES = 2 * 1024 * 1024
    SAMPLE_RECORDS = 256
    SAMPLE_BYTES = 1024 * 1024
    CONTROL_RECORDS = 8

    class Oversize < StandardError; end

    attr_reader :epoch

    def initialize(writer: nil)
      @writer = writer || ->(bytes) { $stdout.write_nonblock(bytes, exception: false) }
      @epoch = SecureRandom.hex(16)
      @mutex = Mutex.new
      @changed = ConditionVariable.new
      @queue = []
      @records = @bytes = @sequence = @failures = 0
      @stopping = false
      @control = reserve(CONTROL_RECORDS, CONTROL_RECORDS * LINE_BYTES)
    end

    def start
      @thread = Thread.new { drain }
    end

    def reserve(records, bytes = records * LINE_BYTES, wait: false)
      @mutex.synchronize do
        loop do
          if @records + records <= RECORDS && @bytes + bytes <= BYTES
            @records += records
            @bytes += bytes
            return [records, bytes]
          end
          return unless wait

          @changed.wait(@mutex)
        end
      end
    end

    def release(ticket)
      return unless ticket

      @mutex.synchronize { release_locked(ticket) }
    end

    # IDs and sequence numbers are assigned only when a complete batch enters
    # the ordered stream. Fragment payload is exact JSON, including arbitrary
    # action progress bytes represented by its own Base64 field.
    def frame(type, fields = {})
      data = { evidence_schema: 1, process_epoch: @epoch, type: }.merge(fields)
      raw = JSON.generate(data)
      return [data] if raw.bytesize <= LINE_BYTES - 160

      raise Oversize, 'logical record exceeds sample bound' if raw.bytesize > SAMPLE_BYTES

      encoded = Base64.strict_encode64(raw)
      count = (encoded.bytesize / 1800.0).ceil
      id = SecureRandom.hex(16)
      Array.new(count) do |part|
        { evidence_schema: 1, process_epoch: @epoch, type: 'fragment', logical_type: type,
          sample_epoch: fields[:sample_epoch], sample_sequence: fields[:sample_sequence], action_id: fields[:action_id],
          fragment_id: id, part: part + 1, parts: count, original_bytes: raw.bytesize,
          encoding: 'base64-json', data: encoded.byteslice(part * 1800, 1800) }
      end
    end

    def batch(records, ticket)
      @mutex.synchronize do
        lines = records.each_with_index.map do |record, i|
          line = JSON.generate(record.merge(event_sequence: @sequence + i + 1)) << "\n"
          raise Oversize, 'evidence line exceeds application limit' if line.bytesize > LINE_BYTES

          line
        end
        bytes = lines.sum(&:bytesize)
        raise Oversize, 'evidence reservation exceeded' if lines.size > ticket[0] || bytes > ticket[1]

        @records -= ticket[0] - lines.size
        @bytes -= ticket[1] - bytes
        ticket[0] = ticket[1] = 0
        @sequence += lines.size
        lines.each { |line| @queue << [line, 0, false] }
        @changed.broadcast
      end
      true
    end

    def control(type, fields = {})
      @mutex.synchronize do
        # A pause is admitted with a margin for resume, shutdown and loss. No
        # repetitive diagnostics are generated while the controller is paused.
        raise 'evidence control reservation exhausted' if @control[0] == 0

        framed = frame(type, fields)
        raise Oversize, 'control fields require fragmentation' unless framed.one?

        record = framed.first
        line = JSON.generate(record.merge(event_sequence: @sequence + 1)) << "\n"
        raise Oversize, 'control record too large' if line.bytesize > LINE_BYTES

        @sequence += 1
        @control[0] -= 1
        @control[1] -= LINE_BYTES
        @bytes -= LINE_BYTES - line.bytesize
        @queue << [line, 0, true]
        @changed.broadcast
      end
      true
    end

    def control_ready?
      @mutex.synchronize { @control[0] >= 4 }
    end

    def status
      @mutex.synchronize { { evidence_records: @records, evidence_bytes: @bytes, evidence_failures: @failures, evidence_pending_records: @queue.size } }
    end

    def stop
      @mutex.synchronize do
        @stopping = true
        @changed.broadcast
      end
      @thread&.join # A blocked sink truthfully keeps graceful stop pending.
    end

    protected

    def release_locked(ticket)
      @records -= ticket[0]
      @bytes -= ticket[1]
      ticket[0] = ticket[1] = 0
      @changed.broadcast
    end

    def drain
      loop do
        head = @mutex.synchronize do
          @changed.wait(@mutex) while @queue.empty? && !@stopping
          return if @queue.empty? && @stopping

          @queue.first
        end
        begin
          count = @writer.call(head[0].byteslice(head[1]..))
          if count.is_a?(Integer) && count > 0 && count <= head[0].bytesize - head[1]
            head[1] += count
            if head[1] == head[0].bytesize
              @mutex.synchronize do
                @queue.shift
                @bytes -= head[0].bytesize
                if head[2]
                  @control[0] += 1
                  @control[1] += LINE_BYTES
                  @bytes += LINE_BYTES
                else
                  @records -= 1
                end
                @changed.broadcast
              end
              next
            end
          elsif count != :wait_writable
            raise IOError, 'invalid evidence sink result'
          end
        rescue Errno::EINTR, IO::WaitWritable
          # Keep the exact head and partial offset.
        rescue StandardError
          @mutex.synchronize { @failures += 1 }
        end
        @mutex.synchronize { @changed.wait(@mutex, 0.05) }
      end
    end
  end
end
