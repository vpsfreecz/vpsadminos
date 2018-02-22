require 'zlib'

module OsCtld
  class Commands::Container::Create < Commands::Logged
    handle :ct_create

    include OsCtl::Lib::Utils::Log

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
          builder.register

          ok
        end
      end
    end

    protected
    def custom_dataset(builder)
      builder.create_root_dataset(offset: false, parents: true)

      if opts[:no_template]
        # the rootfs is already there
        builder.shift_dataset
        builder.configure(opts[:distribution], opts[:version], opts[:arch])
        return
      end

      case opts[:template][:type].to_sym
      when :remote
        from_remote_template(builder)

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
        builder.create_root_dataset(offset: false)
        from_remote_template(builder)

      when :archive
        builder.create_root_dataset(offset: false)
        builder.setup_rootfs
        builder.from_local_template(opts[:template])

      when :stream
        builder.create_root_dataset(offset: false)
        from_stream(builder)

      else
        fail "unknown template type '#{opts[:template][:type]}'"
      end
    end

    def from_stream(builder)
      if opts[:template][:path]
        File.open(opts[:template][:path]) do |f|
          gz = Zlib::GzipReader.new(f)
          recv_stream(builder, gz)
          gz.close
        end

        builder.shift_dataset
        distribution, version, arch = builder.get_distribution_info(opts[:template][:path])

        builder.configure(
          opts[:distribution] || distribution,
          opts[:version] || version,
          opts[:arch] || arch
        )

      else
        client.send({status: true, response: 'continue'}.to_json + "\n", 0)
        recv_stream(builder, client.recv_io)

        builder.shift_dataset
        builder.configure(opts[:distribution], opts[:version], opts[:arch])
      end
    end

    def from_remote_template(builder)
      # TODO: this check is done too late -- the dataset has already been created
      #       and the repo may not exist
      if opts[:repository]
        repo = DB::Repositories.find(opts[:repository], builder.pool)
        error!('repository not found') unless repo
        repos = [repo]

      else
        repos = DB::Repositories.get.select do |repo|
          repo.enabled? && repo.pool == builder.pool
        end
      end

      # Rootfs (private/) has to be set up both before and after
      # template application. Before, to prepare the directory for tar -x,
      # after to ensure correct permission.
      builder.setup_rootfs

      repo = repos.detect do |repo|
        begin
          builder.from_repo_template(repo, opts[:template][:template])

        rescue TemplateNotFound
          next
        end

        true
      end

      error!('template not found') unless repo

      builder.setup_rootfs
    end

    def recv_stream(builder, io)
      builder.from_stream do |recv|
        recv.write(io.read(16*1024)) until io.eof?
      end
    end
  end
end
