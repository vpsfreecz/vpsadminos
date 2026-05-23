module OsVm
  class ShellLog
    def initialize(path)
      @path = path
      @file = File.open(path, 'w')
      @mutex = Mutex.new
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
