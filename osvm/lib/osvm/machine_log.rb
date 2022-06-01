module OsVm
  class MachineLog
    def initialize(path)
      @path = path
      @file = File.open(path, 'w')
    end

    %i(start stop destroy).each do |m|
      define_method(m) do
        log do |io|
          io.puts("ACTION: #{m}")
        end
      end
    end

    def kill(signal)
      log do |io|
        io.puts("ACTION: kill")
        io.puts("SIGNAL: #{signal}")
      end
    end

    def exit(status)
      log do |io|
        io.puts("ACTION: qemu_exit")
        io.puts("STATUS: #{status}")
      end
    end

    def execute_begin(command)
      log_begin do |io|
        io.puts("COMMAND: #{command}")
      end
    end

    def execute_end(status, output)
      log_end do |io|
        io.puts("STATUS: #{status}")
        io.puts("OUTPUT:")
        io.puts(output)
      end
    end

    def execute(command, status, output)
      execute_begin(command)
      execute_end(status, output)
    end

    def close
      file.close
    end

    protected
    attr_reader :path, :file

    def log(&block)
      log_begin
      log_cont(&block)
      log_end
    end

    def log_begin
      @log_begun_at = Time.now
      file.puts("START: #{@log_begun_at}")
      yield(file) if block_given?
      file.flush
    end

    def log_cont
      yield(file)
      file.flush
    end

    def log_end(&block)
      t = Time.now
      file.puts("END: #{t}")
      file.puts("ELAPSED: #{(t - @log_begun_at).round(2)}s")
      file.flush
      log_cont(&block) if block
      file.puts("---")
      file.puts
      file.flush
    end
  end
end
