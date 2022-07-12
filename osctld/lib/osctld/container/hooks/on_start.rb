require 'osctld/container/hooks/base'

module OsCtld
  class Container::Hooks::OnStart < Container::Hooks::Base
    ct_hook :on_start
    blocking true
  end
end
