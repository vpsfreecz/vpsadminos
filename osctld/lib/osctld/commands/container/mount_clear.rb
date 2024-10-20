require 'osctld/commands/logged'

module OsCtld
  class Commands::Container::MountClear < Commands::Logged
    handle :ct_mount_clear

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      manipulate(ct) do
        ct.mounts.clear
        ok
      end
    rescue UnmountError => e
      error("unable to unmount directory from the container: #{e.message}")
    end
  end
end
