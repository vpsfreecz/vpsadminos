require 'osctld/commands/logged'

module OsCtld
  class Commands::Container::Create < Commands::Logged
    handle :ct_create

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::Container

    def find
      pool = DB::Pools.get_or_default(opts[:pool])
      error!('pool not found') unless pool

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

      error!('group not found') unless group

      if !opts[:template].is_a?(::Hash)
        error!('invalid input')

      elsif !opts[:template][:distribution]
        error!('provide distribution')

      elsif !opts[:template][:version]
        error!('provide distribution version')

      elsif !opts[:template][:arch]
        error!('provide architecture')
      end

      builder = Container::Builder.create(
        pool,
        opts[:id],
        user,
        group,
        opts[:dataset] && OsCtl::Lib::Zfs::Dataset.new(opts[:dataset]),
        cmd: self
      )

      error!(builder.errors.join('; ')) unless builder.valid?

      builder
    end

    def execute(builder)
      manipulate(builder.ct) do
        error!('container already exists') unless builder.register

        begin
          if opts[:dataset]
            custom_dataset(builder)

          elsif opts[:template]
            create_new(builder)

          else
            fail 'should not be possible'
          end

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
      )

      return DB::Users.find(name, pool) || (fail 'expected user')
    end

    def custom_dataset(builder)
      builder.create_root_dataset(mapping: false, parents: true)

      if opts[:no_template]
        # the rootfs is already there
        builder.shift_dataset
        builder.configure(opts[:distribution], opts[:version], opts[:arch])
        return
      end

      from_remote_template(builder, opts[:template])
    end

    def create_new(builder)
      if opts[:no_template]
        builder.create_root_dataset(mapping: true)
        builder.setup_rootfs
        builder.configure(opts[:distribution], opts[:version], opts[:arch])
        return
      end

      builder.create_root_dataset(mapping: false)
      from_remote_template(builder, opts[:template])
    end
  end
end
