require 'osctld/commands/logged'

module OsCtld
  class Commands::Container::MapMode < Commands::Logged
    handle :ct_map_mode

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::Container

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      if !Container::MAP_MODES.include?(opts[:map_mode])
        error!('invalid map mode')
      elsif ct.map_mode == opts[:map_mode]
        return ok
      end

      manipulate(ct) do
        error!('container is running') if ct.running?
        guard_no_runtime_generations!(ct, 'container map-mode change')

        if ct.map_mode == 'native' && opts[:map_mode] == 'zfs'
          native_to_zfs(ct)
        elsif ct.map_mode == 'zfs' && opts[:map_mode] == 'native'
          zfs_to_native(ct)
        end

        ct.map_mode = opts[:map_mode]

        ok
      end
    end

    protected

    def native_to_zfs(ct)
      datasets = ct.datasets

      datasets.reverse_each do |ds|
        progress("Unmounting dataset #{ds.relative_name}")
        zfs(:unmount, nil, ds, valid_rcs: [1])
      end

      datasets.each do |ds|
        progress("Setting UID/GID mapping of #{ds.relative_name}")
        zfs(
          :set,
          "uidmap=\"#{ct.uid_map.map(&:to_s).join(',')}\" " \
          "gidmap=\"#{ct.gid_map.map(&:to_s).join(',')}\"",
          ds
        )

        progress("Remounting dataset #{ds.relative_name}")
        zfs(:mount, nil, ds)
      end
    end

    def zfs_to_native(ct)
      datasets = ct.datasets

      datasets.reverse_each do |ds|
        progress("Unmounting dataset #{ds.relative_name}")
        zfs(:unmount, nil, ds, valid_rcs: [1])
      end

      datasets.each do |ds|
        progress("Unsetting UID/GID mapping of #{ds.relative_name}")
        zfs(
          :set,
          'uidmap=none gidmap=none',
          ds
        )

        progress("Remounting dataset #{ds.relative_name}")
        zfs(:mount, nil, ds)
      end
    end
  end
end
