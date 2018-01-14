module OsCtld
  class Commands::Container::MountCreate < Commands::Logged
    handle :ct_mount_create

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      ct.exclusively do
        mnt = Mount.new(opts[:fs], opts[:mountpoint], opts[:type], opts[:opts])

        if ct.mounts.detect { |m| m.mountpoint == mnt.mountpoint }
          next error("mountpoint '#{mnt.mountpoint}' is already mounted")
        end

        ct.mount_add(mnt)
        ok
      end
    end
  end
end
