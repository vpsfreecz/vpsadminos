require 'zlib'

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

      if (opts[:dataset] && !opts[:template] && !opts[:stream]) \
         || (opts[:stream] && opts[:stream][:type] == 'stdin')
        if !opts[:distribution]
          error!('provide distribution')

        elsif !opts[:version]
          error!('provide distribution version')
        end

      elsif !opts[:dataset] && !opts[:template] && !opts[:stream]
        error!('provide template archive, stream or existing dataset')
      end

      builder = Container::Builder.create(
        pool,
        opts[:id],
        user,
        group,
        opts[:dataset] && Zfs::Dataset.new(opts[:dataset]),
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

            elsif opts[:stream]
              from_stream(builder)

            else # the rootfs is already there
              builder.shift_dataset
              builder.configure(opts[:distribution], opts[:version])
            end

          elsif opts[:template]
            builder.create_dataset(offset: false)
            builder.setup_rootfs
            builder.from_template(opts[:template])

          elsif opts[:stream]
            builder.create_dataset(offset: false)
            from_stream(builder)

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
    def from_stream(builder)
      case opts[:stream][:type].to_sym
      when :file
        File.open(opts[:stream][:path]) do |f|
          gz = Zlib::GzipReader.new(f)
          recv_stream(builder, gz)
          gz.close
        end

        builder.shift_dataset
        distribution, version = builder.get_distribution_info(opts[:stream][:path])

        builder.configure(
          opts[:distribution] || distribution,
          opts[:version] || version
        )

      when :stdin
        client.send({status: true, response: 'continue'}.to_json + "\n", 0)
        recv_stream(builder, client.recv_io)

        builder.shift_dataset
        builder.configure(opts[:distribution], opts[:version])

      else
        error!("unsupported stream type '#{opts[:stream][:type]}'")
      end
    end

    def recv_stream(builder, io)
      builder.from_stream do |recv|
        recv.write(io.read(16*1024)) until io.eof?
      end
    end
  end
end
