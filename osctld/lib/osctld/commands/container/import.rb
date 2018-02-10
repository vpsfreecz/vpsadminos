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
        dataset: opts[:dataset] && Zfs::Dataset.new(
          opts[:dataset],
          base: opts[:dataset]
        )
      )
      builder = Container::Builder.new(ct, cmd: self)

      # TODO: check for conflicting configuration
      #   - ip addresses, mac addresses

      error!(builder.errors.join('; ')) unless builder.valid?

      progress('Creating datasets')
      importer.create_datasets(builder)

      builder.setup_ct_dir
      builder.setup_lxc_home

      progress('Loading data streams')
      importer.load_streams(builder)

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
