module OsCtld
  class Commands::Container::MountDelete < Commands::Base
    handle :ct_mount_delete

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      ct.exclusively do
        ct.mount_remove(opts[:mountpoint])
        ok
      end
    end
  end
end
