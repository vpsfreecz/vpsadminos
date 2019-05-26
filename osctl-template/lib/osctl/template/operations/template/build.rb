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
    attr_reader :build_dataset

    # @return [String]
    attr_reader :output_dir

    # @return [String]
    attr_reader :build_id

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
      @build_dataset = File.join(opts[:build_dataset], build_id)
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
    attr_reader :client, :build_dir, :install_dir, :output_tar, :output_stream

    def build
      Operations::Builder::UseOrCreate.run(builder, base_dir)

      root_uid, root_gid = Operations::Builder::GetRootUgid.run(builder)

      zfs(
        :create,
        "-p -o uidmap=0:#{root_uid}:65536 -o gidmap=0:#{root_gid}:65536",
        build_dataset
      )

      @build_dir = zfs(:get, '-H -o value mountpoint', build_dataset).output.strip
      @install_dir = File.join(build_dir, 'private')

      Dir.mkdir(install_dir)

      client.batch do
        client.bind_mount(builder.ctid, base_dir, builder_base_dir)
        client.bind_mount(builder.ctid, install_dir, builder_install_dir)

        client.activate_mount(builder.ctid, builder_base_dir)
        client.activate_mount(builder.ctid, builder_install_dir)
      end

      rc = client.exec(builder.ctid, [
        File.join(builder_base_dir, 'bin', 'runner'),
        'template',
        'build',
        build_id,
        builder_install_dir,
        template.name,
      ])

      if rc != 0
        fail "build of #{template.name} on #{builder.name} failed with "+
             "exit status #{rc}"
      end

      zfs(:unmount, nil, build_dataset)
      zfs(:set, 'uidmap=none gidmap=none', build_dataset)
      zfs(:mount, nil, build_dataset)

      syscmd("tar -czf \"#{output_tar}\" -C \"#{install_dir}\" .")

      zfs(:snapshot, nil, "#{build_dataset}@template")
      syscmd("zfs send #{build_dataset}@template | gzip > #{output_stream}")

      puts "> #{output_tar}"
      puts "> #{output_tar}"
    end

    def cleanup
      client.batch do
        client.ignore_error { client.unmount(builder.ctid, builder_install_dir) }
        client.ignore_error { client.unmount(builder.ctid, builder_base_dir) }
      end

      # TODO: cleanup mountpoints in the builder

      zfs(:destroy, nil, "#{build_dataset}@template", valid_rcs: [1])
      zfs(:destroy, nil, build_dataset, valid_rcs: [1])
    end

    def builder_base_dir
      "/build/basedir.#{build_id}"
    end

    def builder_install_dir
      "/build/installdir.#{build_id}"
    end
  end
end
