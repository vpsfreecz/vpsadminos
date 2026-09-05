require 'fileutils'
require 'libosctl'
require 'osctld/user_control/commands/base'

module OsCtld
  class UserControl::Commands::CtPostMount < UserControl::Commands::Base
    handle :ct_post_mount

    include OsCtl::Lib::Utils::Log

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      ret = authenticate_lifecycle_callback(ct)
      return ret if ret

      root_dir = opts[:rootfs_dir]
      raise IOError, 'mounted rootfs descriptor was not received' unless root_dir && !root_dir.closed?

      rootfs_mount = container_rootfs_mount(ct)
      expected_root_dir = File.open(rootfs_mount, File::RDONLY | File::NOFOLLOW)
      expected_stat = expected_root_dir.stat
      root_stat = root_dir.stat
      raise Errno::ENOTDIR, rootfs_mount unless expected_stat.directory? && root_stat.directory?
      unless root_stat.dev == expected_stat.dev && root_stat.ino == expected_stat.ino
        raise Errno::EXDEV, rootfs_mount
      end

      with_claimed_lifecycle_event(ct, :post_mount, after: :pre_mount) do |run_conf|
        DistConfig.run(
          run_conf,
          :post_mount,
          rootfs_mount:,
          root_dir:,
          ns_pid: peer.pid,
          mnt_ns: peer.namespace(:mnt)
        )

        begin
          Hook.run(
            ct,
            :post_mount,
            rootfs_mount:,
            ns_pid: peer.pid,
            mnt_ns: peer.namespace(:mnt)
          )
        rescue HookFailed => e
          error(e.message)
        else
          ok
        end
      ensure
        root_dir&.close
        root_dir = nil
        expected_root_dir&.close
        expected_root_dir = nil
        peer.release_root

        if ct.map_mode == 'native'
          ct.mounts.shared_dir.cleanup_pushed(run_conf.rootfs)

          ct.mounts.each do |mnt|
            next unless mnt.map_ids

            ct.mounts.shared_dir.cleanup_pushed(mnt.fs)
          end
        end
      end
    rescue SystemCallError, IOError, ArgumentError, TypeError => e
      error("invalid container rootfs or namespace: #{e.message}")
    ensure
      root_dir&.close
      expected_root_dir&.close
    end

    protected

    # LXC runs mount from its cloned setup child, which forks the hook.
    def lifecycle_peer_depth
      2
    end
  end
end
