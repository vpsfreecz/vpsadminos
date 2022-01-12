module TestRunner
  class TestError < ::StandardError ; end

  class TimeoutError < TestError ; end

  class CommandError < TestError ; end

  class CommandSucceeded < CommandError ; end

  class CommandFailed < CommandError ; end
end
