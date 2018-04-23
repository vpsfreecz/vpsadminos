module OsCtld
  class Commands::Container::MountDeactivate < Commands::Logged
    handle :ct_mount_deactivate

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      ct.exclusively do
        error!('the container has to be running') if ct.current_state != :running
        ct.mounts.deactivate(opts[:mountpoint])
        ok
      end

    rescue MountNotFound
      error!('mount not found')
    end
  end
end
