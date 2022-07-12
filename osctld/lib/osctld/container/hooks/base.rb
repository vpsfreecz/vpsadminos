require 'osctld/hook/base'
require 'libosctl'

module OsCtld
  class Container::Hooks::Base < Hook::Base
    # Register container hook under a name
    # @param hook_name [Symbol]
    def self.ct_hook(hook_name)
      hook(Container, hook_name, self)
    end

    # @return [Container]
    attr_reader :ct

    def setup
      @ct = event_instance
    end

    protected
    def environment
      super.merge({
        'OSCTL_POOL_NAME' => ct.pool.name,
        'OSCTL_CT_ID' => ct.id,
        'OSCTL_CT_USER' => ct.user.name,
        'OSCTL_CT_GROUP' => ct.group.name,
        'OSCTL_CT_DATASET' => ct.get_run_conf.dataset.to_s,
        'OSCTL_CT_ROOTFS' => ct.get_run_conf.rootfs,
        'OSCTL_CT_LXC_PATH' => ct.lxc_home,
        'OSCTL_CT_LXC_DIR' => ct.lxc_dir,
        'OSCTL_CT_CGROUP_PATH' => ct.cgroup_path,
        'OSCTL_CT_DISTRIBUTION' => ct.get_run_conf.distribution,
        'OSCTL_CT_VERSION' => ct.get_run_conf.version,
        'OSCTL_CT_HOSTNAME' => ct.hostname.to_s,
        'OSCTL_CT_LOG_FILE' => ct.log_path,
      })
    end
  end
end
