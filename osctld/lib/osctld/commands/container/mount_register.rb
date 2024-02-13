require 'osctld/commands/logged'

module OsCtld
  class Commands::Container::MountRegister < Commands::Logged
    handle :ct_mount_register

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      lock(ct) do
        mnt = Mount::Entry.new(
          opts[:fs],
          opts[:mountpoint],
          opts[:type],
          opts[:opts] || '',
          false,
          temp: true
        )

        if ct.mounts.find_at(mnt.mountpoint)
          next error("mountpoint '#{mnt.mountpoint}' is already mounted")
        end

        ct.mounts.register(mnt)
        ok
      end
    end

    protected

    def lock(ct, &)
      if opts[:lock]
        manipulate(ct, &)

      else
        yield
      end
    end
  end
end
