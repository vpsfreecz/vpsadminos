require 'osctld/container/hooks/base'

module OsCtld
  class Container::Hooks::PostMount < Container::Hooks::Base
    hook :post_mount
    blocking true

    protected
    def environment
      super.merge({
        'OSCTL_CT_ROOTFS_MOUNT' => opts[:rootfs_mount],
      })
    end

    def executable
      ['nsenter', '--target', opts[:ns_pid].to_s, '--mount', hook_path]
    end
  end
end
