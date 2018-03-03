module OsCtld
  class Commands::Container::Import < Commands::Logged
    handle :ct_import

    def find
      DB::Pools.get_or_default(opts[:pool]) || error!('pool not found')
    end

    def execute(pool)
      File.open(opts[:file], 'r') do |f|
        import(pool, f)
      end

      ok
    end

    protected
    def import(pool, io)
      importer = Container::Importer.new(pool, io)
      importer.load_metadata
      ctid = opts[:as_id] || importer.ct_id

      if DB::Containers.find(ctid, pool)
        error!("container #{pool.name}:#{ctid} already exists")
      end

      if opts[:as_user]
        user = DB::Users.find(opts[:as_user], pool)
        error!('user not found') unless user

      else
        user = importer.get_or_create_user
      end

      if opts[:as_group]
        group = DB::Groups.find(opts[:as_group], pool)
        error!('group not found') unless group

      else
        group = importer.get_or_create_group
      end

      ct = importer.load_ct(
        id: ctid,
        user: user,
        group: group,
        dataset: opts[:dataset] && OsCtl::Lib::Zfs::Dataset.new(
          opts[:dataset],
          base: opts[:dataset]
        ),
        ct_opts: {devices: false} # skip device initialization, see below
      )
      builder = Container::Builder.new(ct, cmd: self)

      # TODO: check for conflicting configuration
      #   - ip addresses, mac addresses

      error!(builder.errors.join('; ')) unless builder.valid?

      case opts[:missing_devices]
      when 'provide'
        ct.devices.ensure_all

      when 'remove'
        ct.devices.remove_missing

      else
        begin
          ct.devices.check_all_available!

        rescue DeviceNotAvailable, DeviceModeInsufficient => e
          error!(e.message)
        end
      end

      progress('Creating datasets')
      importer.create_datasets(builder)

      builder.setup_ct_dir
      builder.setup_lxc_home

      progress('Importing rootfs')
      importer.load_rootfs(builder)

      # Delayed initialization, when we have ensured all required devices
      # are present, or that missing devices were removed and rootfs is present,
      # so we can create device nodes
      ct.devices.init

      ct.save_config
      builder.setup_lxc_configs
      builder.setup_log_file
      builder.register

      if ct.netifs.any?
        progress('Reconfiguring LXC usernet')
        call_cmd(Commands::User::LxcUsernet)
      end

      ok
    end
  end
end
