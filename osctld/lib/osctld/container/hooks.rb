require 'osctld/hook/base'

module OsCtld
  module Container::Hooks
    class Base < Hook::Base
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

    class PreStart < Base
      ct_hook :pre_start
      blocking true
    end

    class VethUp < Base
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

    class PreMount < Base
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

    class PostMount < Base
      ct_hook :post_mount
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

    class OnStart < Base
      ct_hook :on_start
      blocking true
    end

    class PostStart < Base
      ct_hook :post_start
      blocking true

      protected
      def environment
        super.merge({
          'OSCTL_CT_INIT_PID' => opts[:init_pid].to_s,
        })
      end
    end

    class PreStop < Base
      ct_hook :pre_stop
      blocking true
    end

    class OnStop < Base
      ct_hook :on_stop
      blocking false
    end

    class VethDown < Base
      ct_hook :veth_down
      blocking false

      protected
      def environment
        super.merge({
          'OSCTL_HOST_VETH' => opts[:host_veth],
          'OSCTL_CT_VETH' => opts[:ct_veth],
        })
      end
    end

    class PostStop < Base
      ct_hook :post_stop
      blocking false
    end
  end
end
