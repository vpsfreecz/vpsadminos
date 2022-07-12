require 'osctld/container/hooks/base'

module OsCtld
  class Container::Hooks::VethUp < Container::Hooks::Base
    ct_hook :veth_up
    blocking true

    protected
    def environment
      super.merge({
        'OSCTL_HOST_VETH' => opts[:host_veth],
        'OSCTL_CT_VETH' => opts[:ct_veth],
      })
    end
  end
end
