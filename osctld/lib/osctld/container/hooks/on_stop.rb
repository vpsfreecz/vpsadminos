module OsCtld
  class Container::Hooks::OnStop < Container::Hooks::Base
    hook :on_stop
    blocking false
  end
end
