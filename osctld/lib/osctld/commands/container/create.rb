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

      builder = Container::Builder.create(pool, opts[:id], user, group, cmd: self)

      unless builder.valid?
        error!("invalid id, allowed format: #{builder.id_chars}")
      end

      builder
    end

    def execute(builder)
      builder.user.inclusively do
        builder.ct.exclusively do
          next error('container already exists') if builder.exist?

          builder.create_dataset(offset: false)
          builder.setup_ct_dir
          builder.setup_rootfs
          builder.setup_lxc_home
          builder.from_template(opts[:template])
          builder.setup_lxc_configs
          builder.setup_log_file
          builder.register

          ok
        end
      end
    end
  end
end
