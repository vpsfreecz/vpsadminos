module OsCtld
  class Commands::Container::MountDelete < Commands::Logged
    handle :ct_mount_delete

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      ct.exclusively do
        # TODO: umount from container if it is running
        ct.mounts.delete_at(opts[:mountpoint])
        ok
      end
    end
  end
end
