module OsCtld
  SystemCommandFailed = OsCtl::Lib::Exceptions::SystemCommandFailed

  class CommandFailed < StandardError ; end
  class CGroupSubsystemNotFound < StandardError ; end
  class CGroupParameterNotFound < StandardError ; end
  class TemplateNotFound < StandardError ; end
  class TemplateRepositoryUnavailable < StandardError ; end
end
