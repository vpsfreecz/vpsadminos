require 'libosctl'
require 'osctl/image/operations/base'
require 'fileutils'
require 'open3'
require 'securerandom'
require 'tmpdir'

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

    # @return [String, nil]
    attr_reader :output_tar

    # @return [String]
    attr_reader :output_stream

    # @return [String, nil]
    attr_reader :vpsadminos_dir

    # @param base_dir [String]
    # @param image [Image]
    # @param opts [Hash]
    # @option opts [String] :build_dataset
    # @option opts [String] :output_dir
    # @option opts [String] :vendor
    # @option opts [String] :vpsadminos_dir
    def initialize(base_dir, image, opts)
      super()
      @base_dir = base_dir
      @opts = opts

      @image = image
      image.load_config

      @builder = Builder.new(base_dir, image.builder)
      builder.load_config

      @build_id = SecureRandom.hex(4)
      @build_dataset = File.join(opts[:build_dataset], build_id)
      @output_dataset = File.join(build_dataset, 'output')
      @work_dataset = File.join(build_dataset, 'work')
      @output_dir = opts[:output_dir]
      @vpsadminos_dir = opts[:vpsadminos_dir]

      name = [
        image.distribution,
        image.version,
        image.arch,
        opts[:vendor] || image.vendor,
        image.variant
      ].join('-')

      @output_tar = File.join(output_dir, "#{name}-archive.tar") if image.datasets.empty?
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
      ret = OsCtl::Lib::ConfigFile.load_yaml_file(config_file)
      File.unlink(config_file)
      ret
    end

    def cached?
      (output_tar && File.exist?(output_tar)) || File.exist?(output_stream)
    end

    def effective_vendor
      @effective_vendor ||= @opts[:vendor] || image.vendor
    end

    def image_attrs
      @image_attrs ||= {
        distribution: image.distribution,
        version: image.version,
        arch: image.arch,
        vendor: effective_vendor,
        variant: image.variant
      }
    end

    def log_type
      "build #{image.name}@#{builder.name}"
    end

    protected

    attr_reader :client, :build_dataset, :work_dir, :opts

    def build
      prepared_vpsadminos_dir = prepare_vpsadminos_dir

      Operations::Builder::UseOrCreate.run(
        builder,
        base_dir,
        vpsadminos_dir: prepared_vpsadminos_dir
      )

      root_uid, root_gid = Operations::Builder::GetRootUgid.run(builder)

      zfs(:create, '-p', work_dataset)
      zfs(:create, '-p', output_dataset)

      image.datasets.each_key do |dataset|
        zfs(:create, '-p', File.join(output_dataset, dataset))
      end

      @work_dir = zfs(:get, '-H -o value mountpoint', work_dataset).output.strip
      @output_dir = zfs(:get, '-H -o value mountpoint', output_dataset).output.strip
      @install_dir = File.join(output_dir, 'private')
      @config_file = File.join(install_dir, 'container.yml')

      Dir.mkdir(install_dir)

      image.datasets.each_key do |dataset|
        Dir.mkdir(File.join(output_dir, dataset, 'private'))
      end

      client.batch do
        # Directory with image-scripts is by default a part of the OS, i.e. usually
        # stored on squashfs, which does not support ID mapping. Read-only access
        # is enough for the build.
        client.bind_mount(builder.ctid, base_dir, builder_base_dir, map_ids: false)

        client.bind_mount(builder.ctid, work_dir, builder_work_dir)
        client.bind_mount(builder.ctid, install_dir, builder_install_dir)

        if prepared_vpsadminos_dir
          client.bind_mount(
            builder.ctid,
            prepared_vpsadminos_dir,
            builder_vpsadminos_dir,
            map_ids: false
          )
        end

        client.activate_mount(builder.ctid, builder_base_dir)
        client.activate_mount(builder.ctid, builder_work_dir)
        client.activate_mount(builder.ctid, builder_install_dir)
        client.activate_mount(builder.ctid, builder_vpsadminos_dir) if prepared_vpsadminos_dir

        image.datasets.sort { |a, b| a[0] <=> b[0] }.each do |dataset, mountpoint|
          install_mountpoint = File.join(builder_install_dir, mountpoint)

          client.bind_mount(
            builder.ctid,
            File.join(output_dir, dataset, 'private'),
            install_mountpoint
          )
          client.activate_mount(builder.ctid, install_mountpoint)
        end
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
          image.name
        ],
        id: build_id,
        client:,
        env: build_environment
      )

      if rc != 0
        raise OperationError,
              "build of #{image.name} on #{builder.name} failed with " \
              "exit status #{rc}"
      end

      sys = OsCtl::Lib::Sys.new
      sys.syncfs(install_dir)

      # Remount just in case to write-out dirtied pages
      zfs(:unmount, nil, output_dataset)
      zfs(:mount, nil, output_dataset)

      Operations::Image::FixFileCapabilities.run(image, install_dir)
      Operations::Image::Export.run(self)
    end

    def cleanup
      client.batch do
        client.ignore_error { client.unmount(builder.ctid, builder_work_dir) }
        client.ignore_error { client.unmount(builder.ctid, builder_vpsadminos_dir) } if vpsadminos_dir

        image.datasets.sort { |a, b| b[0] <=> a[0] }.each do |_, mountpoint|
          install_mountpoint = File.join(builder_install_dir, mountpoint)
          client.ignore_error { client.unmount(builder.ctid, install_mountpoint) }
        end

        client.ignore_error { client.unmount(builder.ctid, builder_install_dir) }
        client.ignore_error { client.unmount(builder.ctid, builder_base_dir) }
      end

      if builder.attrs
        dirs = [builder_base_dir, builder_work_dir, builder_install_dir]
        dirs << builder_vpsadminos_dir if vpsadminos_dir

        dirs.each do |dir|
          Dir.rmdir(File.join(builder.attrs[:rootfs], dir))
        rescue Errno::ENOENT
          # ignore
        end
      end

      zfs(:destroy, nil, work_dataset, valid_rcs: :all)

      list = zfs(:list, '-H -o name -t snapshot', output_dataset, valid_rcs: :all)

      if list.success?
        list.output.split("\n").each do |s|
          zfs(:destroy, nil, s.strip)
        end
      end

      zfs(:destroy, '-r', output_dataset, valid_rcs: :all)
      zfs(:destroy, nil, build_dataset, valid_rcs: :all)
    ensure
      cleanup_vpsadminos_dir
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

    def builder_vpsadminos_dir
      "/build/vpsadminos.#{build_id}"
    end

    def build_environment
      return {} unless vpsadminos_dir

      ret = { 'OSCTL_IMAGE_VPSADMINOS_DIR' => builder_vpsadminos_dir }
      ret['OSCTL_IMAGE_VPSADMINOS_REV'] = vpsadminos_revision if vpsadminos_revision
      ret
    end

    def prepare_vpsadminos_dir
      return unless vpsadminos_dir
      return @prepared_vpsadminos_dir if @prepared_vpsadminos_dir

      dir = Dir.mktmpdir('osctl-image-vpsadminos.')
      FileUtils.cp_r(File.join(vpsadminos_dir, '.'), dir, preserve: true)
      write_vpsadminos_revision(dir)
      FileUtils.rm_rf([File.join(dir, '.git'), File.join(dir, 'result')])
      FileUtils.chmod_R('u+rwX,go+rX', dir)

      @prepared_vpsadminos_dir = dir
    rescue StandardError
      FileUtils.rm_rf(dir) if dir
      raise
    end

    def write_vpsadminos_revision(dir)
      return unless vpsadminos_revision

      File.write(File.join(dir, '.vpsadminos-git-rev'), "#{vpsadminos_revision}\n")
    end

    def vpsadminos_revision
      return @vpsadminos_revision if defined?(@vpsadminos_revision)

      if ENV['OSCTL_IMAGE_VPSADMINOS_REV'] && !ENV['OSCTL_IMAGE_VPSADMINOS_REV'].empty?
        return @vpsadminos_revision = ENV['OSCTL_IMAGE_VPSADMINOS_REV']
      end

      output, status = Open3.capture2e(
        'git',
        '-C',
        vpsadminos_dir,
        'rev-parse',
        '--verify',
        'HEAD'
      )
      @vpsadminos_revision = status.success? ? output.strip : nil
    rescue Errno::ENOENT
      @vpsadminos_revision = nil
    end

    def cleanup_vpsadminos_dir
      return unless @prepared_vpsadminos_dir

      FileUtils.rm_rf(@prepared_vpsadminos_dir)
      @prepared_vpsadminos_dir = nil
    end
  end
end
