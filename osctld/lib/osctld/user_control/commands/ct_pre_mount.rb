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
      return error('access denied') unless owns_ct?(ct)

      run_conf = lifecycle_run_conf(ct)
      return error('managed lifecycle run not found') unless run_conf

      Hook.run(
        ct,
        :pre_mount,
        rootfs_mount: opts[:rootfs_mount],
        ns_pid: opts[:client_pid]
      )

      if ct.map_mode == 'native'
        ct.mounts.shared_dir.map_and_push(run_conf.rootfs, opts[:client_pid])

        begin
          ct.mounts.each do |mnt|
            next unless mnt.map_ids

            ct.mounts.shared_dir.map_and_push(mnt.fs, opts[:client_pid])
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
    rescue HookFailed => e
      error(e.message)
    end
  end
end
