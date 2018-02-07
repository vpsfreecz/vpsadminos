module OsCtld
  class Commands::Container::Create < Commands::Logged
    handle :ct_create

    include Utils::Log

    def find
      pool = DB::Pools.get_or_default(opts[:pool])
      error!('pool not found') unless pool

      user = DB::Users.find(opts[:user], pool)
      error!('user not found') unless user

      if opts[:group]
        group = DB::Groups.find(opts[:group], pool)

      else
        group = DB::Groups.default(pool)
      end

      error!('group not found') unless group

      if opts[:dataset] && !opts[:template]
        if !opts[:distribution]
          error!('provide distribution')

        elsif !opts[:version]
          error!('provide distribution version')
        end

      elsif !opts[:dataset] && !opts[:template]
        error!('provide template or existing dataset')
      end

      builder = Container::Builder.create(
        pool,
        opts[:id],
        user,
        group,
        opts[:dataset],
        cmd: self
      )

      error!(builder.errors.join('; ')) unless builder.valid?

      builder
    end

    def execute(builder)
      builder.user.inclusively do
        builder.ct.exclusively do
          next error('container already exists') if builder.exist?

          if opts[:dataset]
            builder.create_dataset(offset: false, parents: true)

            if opts[:template]
              builder.setup_rootfs
              builder.from_template(
                opts[:template],
                distribution: opts[:distribution],
                version: opts[:version]
              )
            else
              builder.shift_dataset
              builder.configure(opts[:distribution], opts[:version])
            end

          elsif opts[:template]
            builder.create_dataset(offset: false)
            builder.setup_rootfs
            builder.from_template(opts[:template])

          else
            fail 'should not be possible'
          end

          builder.setup_ct_dir
          builder.setup_lxc_home
          builder.setup_lxc_configs
          builder.setup_log_file
          builder.register

          ok
        end
      end
    end
  end
end
