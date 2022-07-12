require 'osctld/container/hooks/base'

module OsCtld
  class Container::Hooks::PreStart < Container::Hooks::Base
    ct_hook :pre_start
    blocking true
  end
end
