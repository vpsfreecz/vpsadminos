module OsCtld
  class UserControl::Commands::CtPostMount < UserControl::Commands::Base
    handle :ct_post_mount

    include OsCtl::Lib::Utils::Log

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct
      return error('access denied') unless owns_ct?(ct)

      Container::Hook.run(
        ct,
        :post_mount,
        rootfs_mount: opts[:rootfs_mount],
        ns_pid: opts[:client_pid],
      )
      ok

    rescue HookFailed => e
      error(e.message)
    end
  end
end
