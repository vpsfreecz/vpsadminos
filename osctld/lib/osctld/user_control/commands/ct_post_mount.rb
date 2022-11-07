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
      return error('access denied') unless owns_ct?(ct)

      run_conf = ct.run_conf

      DistConfig.run(
        run_conf,
        :post_mount,
        rootfs_mount: opts[:rootfs_mount],
        ns_pid: opts[:client_pid],
      )

      lxcfs_worker = run_conf.lxcfs_worker
      lxcfs_params = lxcfs_worker && {
        mountpoint: lxcfs_worker.mountpoint,
        mount_files: lxcfs_worker.mount_files,
      }

      begin
        Hook.run(
          ct,
          :post_mount,
          rootfs_mount: opts[:rootfs_mount],
          ns_pid: opts[:client_pid],
        )
      rescue HookFailed => e
        error(e.message)
      else
        ok(lxcfs: lxcfs_params)
      end
    end
  end
end
