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

      if opts[:no_template] \
          || (opts[:template] && opts[:template][:type] == :stream && opts[:template][:path].nil?)
        if !opts[:distribution]
          error!('provide distribution')

        elsif !opts[:version]
          error!('provide distribution version')

        elsif !opts[:arch]
          error!('provide architecture')
        end

      elsif !opts[:dataset] && !opts[:template]
        error!('provide template archive, stream or existing dataset')
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
            from_local_template(builder)

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

      case opts[:template][:type].to_sym
      when :remote
        from_remote_template(builder, opts[:template])

      when :archive
        builder.setup_rootfs
        builder.from_local_archive(
          opts[:template][:path],
          distribution: opts[:distribution],
          version: opts[:version]
        )

      when :stream
        from_stream(builder)

      else
        fail "unsupported template type #{opts[:template][:type]}"
      end
    end

    def from_local_template(builder)
      if opts[:no_template]
        builder.create_root_dataset(mapping: true)
        builder.setup_rootfs
        builder.configure(opts[:distribution], opts[:version], opts[:arch])
        return
      end

      case opts[:template][:type].to_sym
      when :remote
        builder.create_root_dataset(mapping: false)
        from_remote_template(builder, opts[:template])

      when :archive
        builder.create_root_dataset(mapping: false)
        builder.setup_rootfs
        builder.from_local_archive(opts[:template][:path])

      when :stream
        builder.create_root_dataset(mapping: false)
        from_stream(builder)

      else
        fail "unknown template type '#{opts[:template][:type]}'"
      end
    end
  end
end
