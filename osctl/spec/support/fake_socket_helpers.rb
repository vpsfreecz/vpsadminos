# frozen_string_literal: true

module FakeSocketHelpers
  class LineSocketDouble
    attr_reader :written_lines, :sent_ios

    def initialize(recv_chunks = [])
      @recv_chunks = recv_chunks.dup
      @written_lines = []
      @sent_ios = []
      @closed = false
    end

    def recv(_size)
      @recv_chunks.shift.to_s
    end

    def puts(str)
      @written_lines << str
    end

    def send_io(io)
      @sent_ios << io
    end

    def close
      @closed = true
    end

    def closed?
      @closed
    end
  end

  class NonblockIODouble
    attr_reader :writes

    def initialize(reads = [])
      @reads = reads.dup
      @writes = []
      @closed = false
    end

    def read_nonblock(_size)
      raise IOError, 'closed stream' if @closed
      raise EOFError if @reads.empty?

      value = @reads.shift
      raise value if value.is_a?(Exception)

      value
    end

    def write(data)
      raise IOError, 'closed stream' if @closed

      @writes << data
      data.bytesize
    end

    def flush
      true
    end

    def close
      @closed = true
    end

    def closed?
      @closed
    end
  end
end

RSpec.configure do |config|
  config.include FakeSocketHelpers
end
