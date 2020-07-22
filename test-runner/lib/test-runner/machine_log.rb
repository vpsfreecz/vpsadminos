module TestRunner
  class MachineLog
    def initialize(path)
      @path = path
      @file = File.open(path, 'w')
    end

    %i(start stop kill destroy).each do |m|
      define_method(m) do
        log do |io|
          io.puts("ACTION: #{m}")
        end
      end
    end

    def execute(command, status, output)
      log do |io|
        io.puts("COMMAND: #{command}")
        io.puts("STATUS: #{status}")
        io.puts("OUTPUT:")
        io.puts(output)
      end
    end

    def close
      file.close
    end

    protected
    attr_reader :path, :file

    def log
      file.puts("DATE: #{Time.now}")
      yield(file)
      file.puts("---")
      file.puts
      file.flush
    end
  end
end
