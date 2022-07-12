require 'osctld/container/hooks/base'

module OsCtld
  class Container::Hooks::PreMount < Container::Hooks::Base
    ct_hook :pre_mount
    blocking true

    protected
    def environment
      super.merge({
        'OSCTL_CT_ROOTFS_MOUNT' => opts[:rootfs_mount],
      })
    end

    def executable(hook_path)
      ['nsenter', '--target', opts[:ns_pid].to_s, '--mount', hook_path]
    end
  end
end
