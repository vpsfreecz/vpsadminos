require 'osctld/commands/logged'

module OsCtld
  class Commands::Container::Import < Commands::Logged
    handle :ct_import

    def find
      DB::Pools.get_or_default(opts[:pool]) || error!('pool not found')
    end

    def execute(pool)
      error!('the pool is disabled') unless pool.active?

      File.open(opts[:file], 'r') do |f|
        import(pool, f)
      end

      ok
    end

    protected
    def import(pool, io)
      importer = Container::Importer.new(pool, io, ct_id: opts[:as_id])
      importer.load_metadata

      if !importer.has_ct_id?
        error!('the image does not include container id, specify it')
      end

      ctid = importer.ct_id

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
        ct_opts: {
          devices: false, # skip device initialization, see below
          staged: true,
        }
      )

      manipulate(ct) do
        builder = Container::Builder.new(ct.new_run_conf, cmd: self)

        # TODO: check for conflicting configuration
        #   - ip addresses, mac addresses

        if !builder.valid?
          error!(builder.errors.join('; '))

        elsif !builder.register
          error!("container #{pool.name}:#{ctid} already exists")
        end

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

        builder.setup_lxc_home

        progress('Importing rootfs')
        importer.import_all_datasets(builder)

        builder.setup_ct_dir
        builder.setup_rootfs

        # Delayed initialization, when we have ensured all required devices
        # are present, or that missing devices were removed and rootfs is present,
        # so we can create device nodes
        ct.devices.init

        ct.save_config
        builder.setup_lxc_configs
        builder.setup_log_file
        builder.setup_user_hook_script_dir
        importer.install_user_hook_scripts(ct)
        builder.monitor

        if ct.netifs.any?
          progress('Reconfiguring LXC usernet')
          call_cmd(Commands::User::LxcUsernet)
        end

        ct.state = :complete

        ok
      end
    end
  end
end
