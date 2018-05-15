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

      user = DB::Users.find(opts[:user], pool)
      error!('user not found') unless user

      if opts[:group]
        group = DB::Groups.find(opts[:group], pool)

      else
        group = DB::Groups.default(pool)
      end

      error!('group not found') unless group

      if (opts[:dataset] && opts[:no_template]) \
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
      builder.user.inclusively do
        builder.ct.exclusively do
          next error('container already exists') if builder.exist?

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
          builder.register

          ok
        end
      end

    rescue
      progress('Error occurred, cleaning up')
      ct = builder.ct

      Console.remove(ct)
      zfs(:destroy, '-r', ct.dataset, valid_rcs: [1]) unless opts[:dataset]

      syscmd("rm -rf #{ct.lxc_dir} #{ct.user_hook_script_dir}")
      File.unlink(ct.log_path) if File.exist?(ct.log_path)
      File.unlink(ct.config_path) if File.exist?(ct.config_path)

      DB::Containers.remove(ct)

      begin
        if ct.group.has_containers?(ct.user)
          CGroup.rmpath_all(ct.base_cgroup_path)

        else
          CGroup.rmpath_all(ct.group.full_cgroup_path(ct.user))
        end
      rescue SystemCallError
        # If some of the cgroups are busy, just leave them be
      end

      bashrc = File.join(ct.lxc_dir, '.bashrc')
      File.unlink(bashrc) if File.exist?(bashrc)

      grp_dir = ct.group.userdir(ct.user)

      if !ct.group.has_containers?(ct.user) && Dir.exist?(grp_dir)
        Dir.rmdir(grp_dir)
      end

      raise
    end

    protected
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
