require 'libosctl'
require 'osctl/template/operations/base'
require 'securerandom'

module OsCtl::Template
  class Operations::Template::Build < Operations::Base
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    # @return [String]
    attr_reader :base_dir

    # @return [Template]
    attr_reader :template

    # @return [Builder]
    attr_reader :builder

    # @return [String]
    attr_reader :output_dataset

    # @return [String]
    attr_reader :work_dataset

    # @return [String]
    attr_reader :output_dir

    # @return [String]
    attr_reader :build_id

    # @return [String]
    attr_reader :output_tar

    # @return [String]
    attr_reader :output_stream

    # @param base_dir [String]
    # @param template [Template]
    # @param opts [Hash]
    # @option opts [String] :build_dataset
    # @option opts [String] :output_dir
    # @option opts [String] :vendor
    def initialize(base_dir, template, opts)
      @base_dir = base_dir

      @template = template
      template.load_config

      @builder = Builder.new(base_dir, template.builder)
      builder.load_config

      @build_id = SecureRandom.hex(4)
      @output_dataset = File.join(opts[:build_dataset], build_id, 'output')
      @work_dataset = File.join(opts[:build_dataset], build_id, 'work')
      @output_dir = opts[:output_dir]

      name = [
        template.distribution,
        template.version,
        template.arch,
        opts[:vendor] || template.vendor,
        template.variant,
      ].join('-')

      @output_tar = File.join(output_dir, "#{name}.tar.gz")
      @output_stream = File.join(output_dir, "#{name}.dat.gz")

      @client = OsCtldClient.new
    end

    def execute
      puts "* Template #{template.name} using #{builder.name} builder"
      build
    ensure
      cleanup
    end

    def log_type
      "build #{template.name}@#{builder.name}"
    end

    protected
    attr_reader :client, :work_dir, :output_dir, :install_dir

    def build
      Operations::Builder::UseOrCreate.run(builder, base_dir)

      root_uid, root_gid = Operations::Builder::GetRootUgid.run(builder)

      zfs(
        :create,
        "-p -o uidmap=0:#{root_uid}:65536 -o gidmap=0:#{root_gid}:65536",
        work_dataset
      )
      zfs(
        :create,
        "-p -o uidmap=0:#{root_uid}:65536 -o gidmap=0:#{root_gid}:65536",
        output_dataset
      )

      @work_dir = zfs(:get, '-H -o value mountpoint', work_dataset).output.strip
      @output_dir = zfs(:get, '-H -o value mountpoint', output_dataset).output.strip
      @install_dir = File.join(output_dir, 'private')

      Dir.mkdir(install_dir)

      client.batch do
        client.bind_mount(builder.ctid, base_dir, builder_base_dir)
        client.bind_mount(builder.ctid, work_dir, builder_work_dir)
        client.bind_mount(builder.ctid, install_dir, builder_install_dir)

        client.activate_mount(builder.ctid, builder_base_dir)
        client.activate_mount(builder.ctid, builder_work_dir)
        client.activate_mount(builder.ctid, builder_install_dir)
      end

      rc = Operations::Builder::ControlledExec.run(
        self,
        [
          File.join(builder_base_dir, 'bin', 'runner'),
          'template',
          'build',
          build_id,
          builder_work_dir,
          builder_install_dir,
          template.name,
        ],
        client: client,
      )

      if rc != 0
        fail "build of #{template.name} on #{builder.name} failed with "+
             "exit status #{rc}"
      end

      zfs(:unmount, nil, output_dataset)
      zfs(:set, 'uidmap=none gidmap=none', output_dataset)
      zfs(:mount, nil, output_dataset)

      syscmd("tar -czf \"#{output_tar}\" -C \"#{install_dir}\" .")

      zfs(:snapshot, nil, "#{output_dataset}@template")
      syscmd("zfs send #{output_dataset}@template | gzip > #{output_stream}")

      puts "> #{output_tar}"
      puts "> #{output_tar}"
    end

    def cleanup
      client.batch do
        client.ignore_error { client.unmount(builder.ctid, builder_work_dir) }
        client.ignore_error { client.unmount(builder.ctid, builder_install_dir) }
        client.ignore_error { client.unmount(builder.ctid, builder_base_dir) }
      end

      if builder.attrs
        [builder_base_dir, builder_work_dir, builder_install_dir].each do |dir|
          begin
            Dir.rmdir(File.join(builder.attrs[:rootfs], dir))
          rescue Errno::ENOENT
          end
        end
      end

      zfs(:destroy, nil, work_dataset, valid_rcs: [1])
      zfs(:destroy, nil, "#{output_dataset}@template", valid_rcs: [1])
      zfs(:destroy, nil, output_dataset, valid_rcs: [1])
    end

    def builder_base_dir
      "/build/basedir.#{build_id}"
    end

    def builder_work_dir
      "/build/workdir.#{build_id}"
    end

    def builder_install_dir
      "/build/installdir.#{build_id}"
    end
  end
end
