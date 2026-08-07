module OsVm
  class MachineLog
    def initialize(path)
      @path = path
      @file = File.open(path, 'w')
      @mutex = Mutex.new
    end

    %i[start stop destroy].each do |m|
      define_method(m) do
        log do |io|
          io.puts("ACTION: #{m}")
        end
      end
    end

    def kill(signal)
      log do |io|
        io.puts('ACTION: kill')
        io.puts("SIGNAL: #{signal}")
      end
    end

    def exit(status)
      log do |io|
        io.puts('ACTION: qemu_exit')
        io.puts("STATUS: #{status.exitstatus}")

        if status.signaled?
          io.puts("TERMSIG: #{status.termsig}")
          io.puts("TERMSIG_NAME: SIG#{Signal.signame(status.termsig)}")
          io.puts("COREDUMP: #{status.coredump?}")
        end
      end
    end

    def console_wait_begin(regex)
      log_begin do |io|
        io.puts('ACTION: console-wait')
        io.puts("REGEXP: #{regex.inspect}")
      end
    end

    def console_wait_end(status, error = nil, begun_at = nil)
      log_end(begun_at) do |io|
        io.puts("MATCH: #{status}")
        io.puts("ERROR: #{error}") if error
      end
    end

    def close
      file.close
    end

    protected

    attr_reader :path, :file, :mutex

    def log(&)
      begun_at = log_begin
      log_cont(&)
      log_end(begun_at)
    end

    def log_begin
      begun_at = Time.now

      mutex.synchronize do
        file.puts("START: #{begun_at}")
        yield(file) if block_given?
        file.flush
      end

      begun_at
    end

    def log_cont
      mutex.synchronize do
        yield(file)
        file.flush
      end
    end

    def log_end(begun_at = nil, &block)
      t = Time.now
      started_at = begun_at || t

      mutex.synchronize do
        file.puts("END: #{t}")
        file.puts("ELAPSED: #{(t - started_at).round(2)}s")
        if block
          yield(file)
          file.flush
        end
        file.puts('---')
        file.puts
        file.flush
      end
    end
  end
end
