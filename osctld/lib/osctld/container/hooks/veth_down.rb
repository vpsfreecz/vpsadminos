module OsCtld
  class Container::Hooks::VethDown < Container::Hooks::Base
    hook :veth_down
    blocking false

    protected
    def environment
      super.merge({
        'OSCTL_HOST_VETH' => opts[:host_veth],
        'OSCTL_CT_VETH' => opts[:ct_veth],
      })
    end
  end
end
