require 'osctld/container/hooks/base'

module OsCtld
  class Container::Hooks::PostStop < Container::Hooks::Base
    ct_hook :post_stop
    blocking false
  end
end
