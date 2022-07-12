require 'osctld/container/hooks/base'

module OsCtld
  class Container::Hooks::OnStop < Container::Hooks::Base
    ct_hook :on_stop
    blocking false
  end
end
