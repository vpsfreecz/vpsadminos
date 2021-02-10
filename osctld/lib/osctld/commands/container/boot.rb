require 'osctld/commands/logged'
require 'securerandom'

module OsCtld
  class Commands::Container::Boot < Commands::Logged
    handle :ct_boot

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
        error!('container is running') if ct.running? && !opts[:force]

        # Check rootfs mount
        if opts[:mount_root]
          # Ensure the rootfs is mounted
          ct.mount(force: true)

          root_mnt = Mount::Entry.new(
            ct.rootfs,
            opts[:mount_root],
            'bind',
            'bind,rw,create=dir',
            true,
            temp: true,
            in_config: true,
          )

          mnt_at = ct.mounts.find_at(opts[:mount_root])

          if mnt_at && !mnt_at.temp
            error!("unable to mount rootfs at '#{opts[:mount_root]}': the path "+
                   "is already mounted")
          end
        end

        # Prepare the image
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

        # Prepare a new, temporary dataset
        tmp_name =  "#{ct.dataset}.boot-#{SecureRandom.hex(3)}"
        tmp_ds = OsCtl::Lib::Zfs::Dataset.new(
          tmp_name,
          base: tmp_name,
        )
        tmp_ds.create!(properties: {
          canmount: 'noauto',
        }.merge(opts[:zfs_properties] || {}))

        ctrc = ct.new_run_conf
        builder = Container::Builder.new(ctrc, cmd: self)

        # Open the image
        fh = File.open(tpl_path, 'r')
        importer = Container::Importer.new(ct.pool, fh, ct_id: ct.id)
        importer.load_metadata

        # Reconfigure the container for boot
        ct_cfg = importer.get_container_config

        ctrc.boot_from(
          tmp_ds,
          ct_cfg['distribution'] || ct.distribution,
          ct_cfg['version'] || ct.version,
          ct_cfg['arch'] || ct.arch,
          destroy_dataset_on_stop: true,
        )

        # Apply the image
        importer.import_root_dataset(builder)
        builder.shift_dataset
        builder.setup_ct_dir
        builder.setup_rootfs

        # Ensure the container is stopped
        call_cmd!(
          Commands::Container::Stop,
          pool: ct.pool.name,
          id: ct.id,
        )

        # Apply run configuration
        ct.set_next_run_conf(ctrc)

        # Boot it
        call_cmd!(
          Commands::Container::Start,
          pool: ct.pool.name,
          id: ct.id,
          wait: opts[:wait],
          mounts: [root_mnt].compact,
        )

        ok
      end

    ensure
      fh && fh.close
    end
  end
end
