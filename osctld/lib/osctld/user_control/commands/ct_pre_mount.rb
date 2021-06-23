require 'libosctl'
require 'osctld/user_control/commands/base'

module OsCtld
  class UserControl::Commands::CtPreMount < UserControl::Commands::Base
    handle :ct_pre_mount

    include OsCtl::Lib::Utils::Log

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct
      return error('access denied') unless owns_ct?(ct)

      # Mount the container's datasets within the mount namespace
      ContainerControl::Commands::WithRootfs.run!(
        ct,
        ns_pid: opts[:client_pid],
        recursive: true,
        block: Proc.new do
          mount_datasets(ct.run_conf)
        end,
      )

      # Configure the system
      DistConfig.run(ct.run_conf, :start, {}, ns_pid: opts[:client_pid])

      Container::Hook.run(
        ct,
        :pre_mount,
        rootfs_mount: opts[:rootfs_mount],
        ns_pid: opts[:client_pid],
      )
      ok

    rescue HookFailed => e
      error(e.message)
    end

    protected
    # Mount datasets from container mounts
    def mount_datasets(ctrc)
      to_mount = []

      ctrc.ct.mounts.each do |mnt|
        next if mnt.dataset.nil? || !mnt.dataset.subdataset_of?(ctrc.dataset)
        to_mount << mnt.dataset
      end

      to_mount.sort { |a, b| a.mountpoint <=> b.mountpoint }.each(&:mount)
    end
  end
end
