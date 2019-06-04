require 'osctld/commands/logged'

module OsCtld
  class Commands::Container::Reinstall < Commands::Logged
    handle :ct_reinstall

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::Container

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!("container not found")
    end

    def execute(ct)
      fh = nil

      manipulate(ct) do
        error!('container is running') if ct.running?

        if opts[:type] == 'image'
          tpl_path = opts[:path]
        elsif opts[:type] == 'remote'
          progress('Fetching image')

          tpl = opts[:image]
          tpl[:distribution] ||= ct.distribution
          tpl[:version] ||= ct.version
          tpl[:arch] ||= ct.arch
          tpl[:vendor] ||= 'default'
          tpl[:variant] ||= 'default'

          tpl_path = get_image_path(get_repositories(ct.pool), tpl)
          error!('image not found in searched repositories') if tpl_path.nil?
        else
          error!('invalid type')
        end

        builder = Container::Builder.new(ct, cmd: self)

        # Remove all snapshots
        snaps = snapshots(ct)

        if snaps.any? && !opts[:remove_snapshots]
          error!("the dataset has snapshots:\n  #{snaps.join("\n  ")}")
        end

        snaps.each { |snap| zfs(:destroy, nil, snap) }

        # Ensure the container is mounted
        ct.mount(force: true)

        # Apply new image
        fh = File.open(tpl_path, 'r')
        importer = Container::Importer.new(ct.pool, fh, ct_id: ct.id)
        importer.load_metadata

        remove_rootfs(builder)
        importer.import_root_dataset(builder)

        dist, ver, arch = importer.get_distribution_info
        ct.set(distribution: {name: dist, version: ver, arch: arch})

        # Remount all subdatasets (subdatasets are unmounted because the builder
        # unmounted them to configure uid/gid mapping again)
        ct.dataset.descendants.each { |ds| zfs(:mount, nil, ds) }

        ok
      end

    ensure
      fh && fh.close
    end

    protected
    def remove_rootfs(builder)
      progress('Removing rootfs')
      snap = "#{builder.ct.dataset}@osctl-reinstall"
      zfs(:snapshot, nil, snap)
      syscmd("rm -rf \"#{builder.ct.rootfs}\"")
      zfs(:destroy, nil, snap)
    end

    def snapshots(ct)
      zfs(:list, '-H -r -d 1 -o name -t snapshot', ct.dataset).output.split("\n")
    end
  end
end
