require 'libosctl'
require 'osctl/image/operations/base'
require 'securerandom'

module OsCtl::Image
  class Operations::Image::Export < Operations::Base
    include OsCtl::Lib::Utils::Log

    # @return [Operations::Image::Build]
    attr_reader :build

    # @param build [Operations::Image::Build]
    def initialize(build)
      @build = build
      @container_config = ContainerConfig.new

      container_config.distribution = build.image.distribution
      container_config.version = build.image.version
      container_config.arch = build.image.arch
      container_config.dataset = OsCtl::Lib::Zfs::Dataset.new(
        build.output_dataset,
        base: build.output_dataset,
      )
      container_config.rootfs = build.install_dir

      if build.has_config_file?
        container_config.override_with(build.read_config_file)
      end
    end

    def execute
      export_archive
      export_stream
    end

    protected
    attr_reader :container_config

    def export_archive
      f = File.open(build.output_tar, 'w')
      exporter = OsCtl::Lib::Exporter::Tar.new(
        container_config,
        f,
        compression: :auto,
      )

      exporter.dump_metadata('full')
      exporter.dump_configs
      exporter.pack_rootfs

    ensure
      f && f.close
    end

    def export_stream
      f = File.open(build.output_stream, 'w')
      exporter = OsCtl::Lib::Exporter::Zfs.new(
        container_config,
        f,
        compression: :gzip,
        compressed_send: true,
      )

      exporter.dump_metadata('full')
      exporter.dump_configs
      exporter.dump_rootfs do
        exporter.dump_base
      end

    ensure
      f && f.close
    end
  end
end
