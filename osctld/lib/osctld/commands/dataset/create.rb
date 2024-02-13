require 'osctld/commands/base'

module OsCtld
  class Commands::Dataset::Create < Commands::Base
    handle :ct_dataset_create

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      manipulate(ct) do
        ds = OsCtl::Lib::Zfs::Dataset.new(
          File.join(ct.dataset.name, opts[:name]),
          base: ct.dataset.name
        )
        parents = ds.relative_parents.reverse! # top-level to deepest level
        created = []

        begin
          (parents + [ds]).each do |ds|
            next if ds.exist?

            ds.create!(
              properties: {
                uidmap: ct.uid_map.map(&:to_s).join(','),
                gidmap: ct.gid_map.map(&:to_s).join(','),
                canmount: 'noauto'
              }
            )
            ds.mount
            ds.create_private!

            created << ds
          end
        rescue SystemCommandFailed
          error!('unable to create dataset, perhaps a parent dataset is missing?')
        end

        next ok if created.empty? || !opts[:mount]

        # Mount newly created parents
        created[0..-2].each do |ds|
          parent_mnt = parent_mountpoint(ct, ds)
          next unless parent_mnt

          mount(ct, ds, File.join(parent_mnt, ds.base_name))
        end

        # Mount target dataset
        parent_mnt = parent_mountpoint(ct, ds)

        if opts[:mountpoint]
          mount(ct, ds, opts[:mountpoint])

        elsif parent_mnt
          mount(ct, ds, File.join(parent_mnt, ds.base_name))
        end

        ok
      end
    end

    protected

    def mount(ct, ds, mountpoint)
      call_cmd!(
        Commands::Container::MountDataset,
        id: ct.id,
        pool: ct.pool.name,
        name: ds.relative_name,
        mountpoint:,
        mode: 'rw',
        automount: opts[:mount]
      )
    end

    def parent_mountpoint(ct, ds)
      parent = ds.parent

      if parent.root?
        '/'
      else
        mnt = ct.mounts.detect { |m| m.dataset.name == parent.name }
        mnt && mnt.mountpoint
      end
    end
  end
end
