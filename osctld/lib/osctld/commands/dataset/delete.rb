require 'osctld/commands/base'

module OsCtld
  class Commands::Dataset::Delete < Commands::Base
    handle :ct_dataset_delete

    include OsCtl::Lib::Utils::Log
    include Utils::SwitchUser

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      name = opts[:name].strip

      if name.empty? || name == '/'
        return error('cannot delete the root dataset')
      end

      ct.exclusively do
        ds = OsCtl::Lib::Zfs::Dataset.new(
          File.join(ct.dataset.name, name),
          base: ct.dataset.name
        )
        error!("dataset #{ds.name} does not exist") unless ds.exist?

        descendants = ds.descendants

        if descendants.any? && !opts[:recursive]
          error!('dataset has children, recursive delete has to be enabled explicitly')
        end

        mounts = find_mounts(ct, ds, descendants, opts[:recursive])

        if mounts.any?
          error!(
            "the following mountpoints need to be unmounted:\n  "+
            mounts.map { |m| m.mountpoint }.join("\n  ")
          ) if !opts[:unmount]

          delete_mounts(ct, mounts)
        end

        begin
          ds.destroy!(recursive: opts[:recursive])
          ok

        rescue SystemCommandFailed => e
          log(:warn, "Unable to delete dataset: #{e.message}")
          error('delete failed, the dataset is either busy or has children')
        end
      end
    end

    protected
    def find_mounts(ct, ds, descendants, recursive)
      datasets = [ds]
      datasets.concat(descendants) if recursive

      ct.mounts.select do |mnt|
        next(false) unless mnt.dataset
        datasets.detect { |ds| ds.relative_name == mnt.dataset.relative_name }
      end.sort { |a, b| a.mountpoint <=> b.mountpoint}.reverse!
    end

    def delete_mounts(ct, mounts)
      if ct.state == :running
        mounts.each do |mnt|
          next unless Dir.exist?(File.join(ct.runtime_rootfs, mnt.mountpoint))

          begin
            ret = ct_syscmd(
              ct,
              "umount #{File.join('/', mnt.mountpoint)}",
              valid_rcs: [1]
            )

            if ret[:exitstatus] == 1 && /not mounted/ !~ ret[:output]
              error!("unable to unmount #{mnt.mountpoint}: #{ret[:output]}")
            end

          rescue SystemCommandFailed => e
            error!("unable to unmount #{mnt.mountpoint}: #{e.message}")
          end
        end
      end

      mounts.each do |mnt|
        ct.mount_remove(mnt.mountpoint)
      end
    end
  end
end
