module OsVm
  class ShellLog
    def initialize(path, shell_index: nil, shell_name: nil)
      @path = path
      @file = File.open(path, 'w')
      @mutex = Mutex.new

      return unless shell_name || shell_index

      file.puts("SHELL: #{shell_name || shell_index}")
      file.puts
    end

    def execute_begin(command)
      log_begin do |io|
        io.puts("COMMAND: #{command}")
      end
    end

    def execute_end(status, output, begun_at)
      log_end(begun_at) do |io|
        io.puts("STATUS: #{status}")
        io.puts('OUTPUT:')
        io.puts(output)
      end
    end

    def execute(command, status, output)
      begun_at = execute_begin(command)
      execute_end(status, output, begun_at)
    end

    def execute_timeout(error, trace)
      buffer = trace[:reply_buffer].to_s
      begun_at = log_begin do |io|
        io.puts('ACTION: protocol-timeout')
        io.puts("PHASE: #{trace[:failed_phase] || trace[:phase]}")
      end
      log_end(begun_at) do |io|
        io.puts("ERROR: #{error.class}: #{error.message[0, 4096]}")
        io.puts("PROTOCOL_ERROR: #{trace[:protocol_error][0, 4096]}") if trace[:protocol_error]
        io.puts("REPLY_BUFFER_BYTES: #{buffer.bytesize}")
        io.puts("REPLY_BUFFER_PREFIX: #{buffer.byteslice(0, 32_768).inspect}")
      end
    rescue IOError, SystemCallError
      # An unavailable log must not replace the command's original timeout.
      nil
    end

    def close
      file.close
    end

    protected

    attr_reader :path, :file, :mutex

    def log_begin
      begun_at = Time.now

      mutex.synchronize do
        file.puts("START: #{begun_at}")
        yield(file) if block_given?
        file.flush
      end

      begun_at
    end

    def log_end(begun_at)
      t = Time.now

      mutex.synchronize do
        file.puts("END: #{t}")
        file.puts("ELAPSED: #{(t - begun_at).round(2)}s")
        yield(file)
        file.puts('---')
        file.puts
        file.flush
      end
    end
  end
end
