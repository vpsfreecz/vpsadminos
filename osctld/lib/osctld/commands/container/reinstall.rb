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
      manipulate(ct) do
        error!('container is running') if ct.running?

        builder = Container::Builder.new(ct, cmd: self, reinstall: true)

        # Remove all snapshots
        snaps = snapshots(ct)

        if snaps.any? && !opts[:remove_snapshots]
          error!("the dataset has snapshots:\n  #{snaps.join("\n  ")}")
        end

        snaps.each { |snap| zfs(:destroy, nil, snap) }

        # Ensure the container is mounted
        ct.mount(force: true)

        # Apply new template
        apply_template(builder, opts[:template])

        # Remount all subdatasets (subdatasets are unmounted because the builder
        # unmounted them to configure uid/gid mapping again)
        ct.dataset.descendants.each { |ds| zfs(:mount, nil, ds) }

        ok
      end
    end

    protected
    def apply_template(builder, tpl)
      case tpl[:type].to_sym
      when :remote
        remove_rootfs(builder)

        tpl[:template][:distribution] ||= builder.ct.distribution
        tpl[:template][:version] ||= builder.ct.version
        tpl[:template][:arch] ||= builder.ct.arch
        tpl[:template][:vendor] ||= 'default'
        tpl[:template][:variant] ||= 'default'

        from_remote_template(builder, tpl)

      when :archive
        remove_rootfs(builder)
        builder.setup_rootfs
        builder.from_local_archive(tpl[:path])

      when :stream
        from_stream(builder)

      else
        fail "unknown template type '#{tpl[:type]}'"
      end
    end

    def remove_rootfs(builder)
      progress('Removing rootfs')
      snap = "#{builder.ct.dataset}@osctl-reinstall"
      zfs(:snapshot, nil, snap)
      syscmd("rm -rf \"#{builder.ct.rootfs}\"")
      zfs(:destroy, nil, snap)
    end

    def snapshots(ct)
      zfs(:list, '-H -r -d 1 -o name -t snapshot', ct.dataset)[:output].split("\n")
    end
  end
end
