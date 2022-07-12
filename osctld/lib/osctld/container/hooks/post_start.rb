require 'osctld/container/hooks/base'

module OsCtld
  class Container::Hooks::PostStart < Container::Hooks::Base
    ct_hook :post_start
    blocking true

    protected
    def environment
      super.merge({
        'OSCTL_CT_INIT_PID' => opts[:init_pid].to_s,
      })
    end
  end
end
