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

      if ct.map_mode == 'native'
        ct.mounts.shared_dir.cleanup_pushed(run_conf.rootfs)

        ct.mounts.each do |mnt|
          next unless mnt.map_ids

          ct.mounts.shared_dir.cleanup_pushed(mnt.fs)
        end
      end

      DistConfig.run(
        run_conf,
        :post_mount,
        rootfs_mount: opts[:rootfs_mount],
        ns_pid: opts[:client_pid]
      )

      begin
        Hook.run(
          ct,
          :post_mount,
          rootfs_mount: opts[:rootfs_mount],
          ns_pid: opts[:client_pid]
        )
      rescue HookFailed => e
        error(e.message)
      else
        ok
      end
    end
  end
end
