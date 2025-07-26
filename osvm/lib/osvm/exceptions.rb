module OsVm
  class Error < ::StandardError; end

  class TimeoutError < Error; end

  class UnrecoverableTimeoutError < TimeoutError; end

  class CommandError < Error; end

  class CommandSucceeded < CommandError; end

  class CommandFailed < CommandError; end

  class MachineShellClosed < CommandError; end
end
