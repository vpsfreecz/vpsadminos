require 'libosctl'
require 'osctl/image/operations/base'
require 'securerandom'
require 'yaml'

module OsCtl::Image
  class Operations::Image::Build < Operations::Base
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    # @return [String]
    attr_reader :base_dir

    # @return [Image]
    attr_reader :image

    # @return [Builder]
    attr_reader :builder

    # @return [String]
    attr_reader :output_dataset

    # @return [String]
    attr_reader :work_dataset

    # @return [String]
    attr_reader :output_dir

    # @return [String]
    attr_reader :install_dir

    # @return [String]
    attr_reader :config_file

    # @return [String]
    attr_reader :build_id

    # @return [String]
    attr_reader :output_tar

    # @return [String]
    attr_reader :output_stream

    # @param base_dir [String]
    # @param image [Image]
    # @param opts [Hash]
    # @option opts [String] :build_dataset
    # @option opts [String] :output_dir
    # @option opts [String] :vendor
    def initialize(base_dir, image, opts)
      @base_dir = base_dir

      @image = image
      image.load_config

      @builder = Builder.new(base_dir, image.builder)
      builder.load_config

      @build_id = SecureRandom.hex(4)
      @build_dataset = File.join(opts[:build_dataset], build_id)
      @output_dataset = File.join(build_dataset, 'output')
      @work_dataset = File.join(build_dataset, 'work')
      @output_dir = opts[:output_dir]

      name = [
        image.distribution,
        image.version,
        image.arch,
        opts[:vendor] || image.vendor,
        image.variant,
      ].join('-')

      @output_tar = File.join(output_dir, "#{name}-archive.tar")
      @output_stream = File.join(output_dir, "#{name}-stream.tar")

      @client = OsCtldClient.new
    end

    # @return [Operations::Image::Build]
    def execute
      log(:info, "Using builder #{builder.name}")
      build
      self
    ensure
      cleanup
    end

    def has_config_file?
      File.exist?(config_file)
    end

    def read_config_file
      ret = YAML.load_file(config_file)
      File.unlink(config_file)
      ret
    end

    def cached?
      File.exist?(output_tar) || File.exist?(output_stream)
    end

    def log_type
      "build #{image.name}@#{builder.name}"
    end

    protected
    attr_reader :client, :build_dataset, :work_dir, :output_dir

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
      @config_file = File.join(install_dir, 'container.yml')

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
        builder,
        [
          File.join(builder_base_dir, 'bin', 'runner'),
          'image',
          'build',
          build_id,
          builder_work_dir,
          builder_install_dir,
          image.name,
        ],
        id: build_id,
        client: client,
      )

      if rc != 0
        raise OperationError,
              "build of #{image.name} on #{builder.name} failed with "+
              "exit status #{rc}"
      end

      zfs(:unmount, nil, output_dataset)
      zfs(:set, 'uidmap=none gidmap=none', output_dataset)
      zfs(:mount, nil, output_dataset)

      Operations::Image::Export.run(self)
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

      zfs(:destroy, nil, work_dataset, valid_rcs: :all)

      list = zfs(:list, '-H -o name -t snapshot', output_dataset, valid_rcs: :all)

      if list.success?
        list.output.split("\n").each do |s|
          zfs(:destroy, nil, s.strip)
        end
      end

      zfs(:destroy, nil, output_dataset, valid_rcs: :all)
      zfs(:destroy, nil, build_dataset, valid_rcs: :all)
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
