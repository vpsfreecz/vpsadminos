module OsVm
  class Error < ::StandardError; end

  class TimeoutError < Error; end

  class UnrecoverableTimeoutError < TimeoutError; end

  class KernelFailure < Error
    attr_reader :machine_name, :console_line, :console_log_path

    def initialize(machine_name:, console_line:, console_log_path:)
      @machine_name = machine_name
      @console_line = console_line
      @console_log_path = console_log_path

      super(
        "Kernel failure detected in machine #{machine_name.inspect}: " \
        "#{console_line.inspect}; see #{console_log_path}"
      )
    end
  end

  class CommandError < Error; end

  class CommandSucceeded < CommandError; end

  class CommandFailed < CommandError; end

  class MachineShellClosed < CommandError; end
end
