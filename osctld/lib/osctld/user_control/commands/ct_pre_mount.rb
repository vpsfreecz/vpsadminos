require 'libosctl'
require 'osctld/user_control/commands/base'

module OsCtld
  class UserControl::Commands::CtPreMount < UserControl::Commands::Base
    handle :ct_pre_mount

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      ret = authenticate_lifecycle_callback(ct)
      return ret if ret

      rootfs_mount = container_rootfs_mount(ct)
      with_claimed_lifecycle_event(ct, :pre_mount, after: :pre_start) do |run_conf|
        Hook.run(
          ct,
          :pre_mount,
          rootfs_mount:,
          ns_pid: peer.pid,
          mnt_ns: peer.namespace(:mnt)
        )

        if ct.map_mode == 'native'
          ct.mounts.shared_dir.map_and_push(
            run_conf.rootfs,
            peer.namespace(:user)
          )

          begin
            ct.mounts.each do |mnt|
              next unless mnt.map_ids

              ct.mounts.shared_dir.map_and_push(
                mnt.fs,
                peer.namespace(:user)
              )
            end
          rescue SystemCommandFailed
            log(:warn, 'Failed to map and push a mount, cleaning up')

            ct.mounts.shared_dir.cleanup_pushed(run_conf.rootfs)

            ct.mounts.each do |mnt|
              next unless mnt.map_ids

              ct.mounts.shared_dir.cleanup_pushed(mnt.fs)
            end

            raise
          end
        end

        ok
      end
    rescue HookFailed => e
      error(e.message)
    rescue SystemCallError, IOError, ArgumentError, TypeError => e
      error("invalid container rootfs or namespace: #{e.message}")
    end

    protected

    # LXC runs pre-mount from its cloned setup child, which forks the hook.
    def lifecycle_peer_depth
      2
    end
  end
end
