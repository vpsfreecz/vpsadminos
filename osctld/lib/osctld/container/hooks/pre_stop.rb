module OsCtld
  class Container::Hooks::PreStop < Container::Hooks::Base
    hook :pre_stop
    blocking true
  end
end
