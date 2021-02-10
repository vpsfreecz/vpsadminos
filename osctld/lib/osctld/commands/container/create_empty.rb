require 'osctld/commands/logged'

module OsCtld
  class Commands::Container::CreateEmpty < Commands::Logged
    handle :ct_create_empty

    def find
      pool = DB::Pools.get_or_default(opts[:pool])
      error!('pool not found') unless pool

      if DB::Containers.find(opts[:id], pool)
        error!("container #{pool.name}:#{opts[:id]} already exists")
      end

      if opts[:user]
        user = DB::Users.find(opts[:user], pool)
        error!('user not found') unless user
      else
        user = create_user(pool)
      end

      if opts[:group]
        group = DB::Groups.find(opts[:group], pool)
      else
        group = DB::Groups.default(pool)
      end

      if !opts[:distribution]
        error!('provide distribution')

      elsif !opts[:version]
        error!('provide distribution version')

      elsif !opts[:arch]
        error!('provide architecture')
      end

      builder = Container::Builder.create(
        pool,
        opts[:id],
        user,
        group,
        opts[:dataset] && OsCtl::Lib::Zfs::Dataset.new(
          opts[:dataset],
          base: opts[:dataset],
        ),
        cmd: self
      )

      error!(builder.errors.join('; ')) unless builder.valid?

      builder
    end

    def execute(builder)
      manipulate(builder.ctrc.ct) do
        error!('container already exists') unless builder.register

        begin
          builder.create_root_dataset(mapping: true, parents: true)
          builder.shift_dataset if opts[:dataset]
          builder.configure(opts[:distribution], opts[:version], opts[:arch])
          builder.setup_ct_dir
          builder.setup_lxc_home
          builder.setup_lxc_configs
          builder.setup_log_file
          builder.setup_user_hook_script_dir
          builder.monitor
          ok

        rescue
          progress('Error occurred, cleaning up')
          builder.cleanup(dataset: !opts[:dataset])
          raise
        end
      end
    end

    protected
    def create_user(pool)
      name = opts[:id]

      user = DB::Users.find(name, pool)
      return user if user

      call_cmd!(
        Commands::User::Create,
        pool: pool.name,
        name: name,
        standalone: false,
      )

      return DB::Users.find(name, pool) || (fail 'expected user')
    end
  end
end
