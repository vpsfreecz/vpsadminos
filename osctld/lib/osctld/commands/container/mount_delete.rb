module OsCtld
  class Commands::Container::MountDelete < Commands::Logged
    handle :ct_mount_delete

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      ct.exclusively do
        ct.mounts.delete_at(opts[:mountpoint])
        ok
      end

    rescue UnmountError
      error('unable to unmount the directory from the container')
    end
  end
end
