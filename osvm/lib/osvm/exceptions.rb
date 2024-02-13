module OsVm
  class Error < ::StandardError; end

  class TimeoutError < Error; end

  class CommandError < Error; end

  class CommandSucceeded < CommandError; end

  class CommandFailed < CommandError; end
end
