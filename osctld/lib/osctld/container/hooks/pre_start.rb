module OsCtld
  class Container::Hooks::PreStart < Container::Hooks::Base
    hook :pre_start
    blocking true
  end
end
