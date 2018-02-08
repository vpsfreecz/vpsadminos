module OsCtld
  class SystemCommandFailed < StandardError ; end
  class CommandFailed < StandardError ; end
  class CGroupSubsystemNotFound < StandardError ; end
  class CGroupParameterNotFound < StandardError ; end
end
