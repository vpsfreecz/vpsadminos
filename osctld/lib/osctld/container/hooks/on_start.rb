require 'osctld/container/hooks/base'

module OsCtld
  class Container::Hooks::OnStart < Container::Hooks::Base
    hook :on_start
    blocking true
  end
end
