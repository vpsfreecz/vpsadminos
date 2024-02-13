module OsCtl::Lib
  class SystemCommandResult
    # @return [Integer]
    attr_reader :exitstatus

    # @return [String]
    attr_reader :output

    # @param exitstatus [Integer]
    # @param output [String]
    def initialize(exitstatus, output)
      @exitstatus = exitstatus
      @output = output
    end

    def success?
      exitstatus == 0
    end

    def error?
      !success?
    end

    def [](key)
      warn "Accessing command result using [#{key}] is deprecated"
      warn 'Caller backtrace:'
      warn caller.join("\n")
      send(key)
    end
  end
end
