require 'osctld/commands/logged'

module OsCtld
  class Commands::Container::MountCreate < Commands::Logged
    handle :ct_mount_create

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      ct.exclusively do
        mnt = Mount::Entry.new(
          opts[:fs],
          opts[:mountpoint],
          opts[:type],
          opts[:opts],
          opts[:automount],
        )

        if ct.mounts.find_at(mnt.mountpoint)
          next error("mountpoint '#{mnt.mountpoint}' is already mounted")
        end

        ct.mounts.add(mnt)
        ok
      end
    end
  end
end
