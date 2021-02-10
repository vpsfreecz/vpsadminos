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

        builder = Container::Builder.new(ct.new_run_conf, cmd: self)

        # Remove all snapshots
        snaps = snapshots(ct)

        if snaps.any? && !opts[:remove_snapshots]
          error!("the dataset has snapshots:\n  #{snaps.join("\n  ")}")
        end

        snaps.each { |snap| zfs(:destroy, nil, snap) }

        # Unmount all datasets
        ct.dataset.unmount(recursive: true)

        # Create a new rootfs dataset with temporary name
        props = OsCtl::Lib::Zfs::PropertyState.new
        props.read_from(ct.dataset)

        new_ds = OsCtl::Lib::Zfs::Dataset.new("#{ct.dataset}.reinstall")
        new_ds.create!(properties: props.options)

        # Move subdatasets to the new dataset
        ct.dataset.children.each do |ds|
          new_subds = File.join(new_ds.name, ds.relative_name)
          zfs(:rename, nil, "#{ds} #{new_subds}")
        end

        # Destroy the original rootfs dataset
        zfs(:destroy, nil, ct.dataset)

        # Replace the original dataset with the new one
        zfs(:rename, nil, "#{new_ds} #{ct.dataset}")

        # Apply new image
        fh = File.open(tpl_path, 'r')
        importer = Container::Importer.new(ct.pool, fh, ct_id: ct.id)
        importer.load_metadata
        importer.import_root_dataset(builder)

        # Update image-specific config
        ct.patch_config(importer.get_container_config)

        # Remount all datasets
        ct.dataset.mount(recursive: true)

        builder.setup_ct_dir
        builder.setup_rootfs

        ok
      end

    ensure
      fh && fh.close
    end

    protected
    def snapshots(ct)
      zfs(:list, '-H -r -d 1 -o name -t snapshot', ct.dataset).output.split("\n")
    end
  end
end
