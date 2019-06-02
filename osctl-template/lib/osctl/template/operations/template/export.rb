require 'libosctl'
require 'osctl/template/operations/base'
require 'securerandom'

module OsCtl::Template
  class Operations::Template::Export < Operations::Base
    include OsCtl::Lib::Utils::Log

    # @return [Operations::Template::Build]
    attr_reader :build

    # @param build [Operations::Template::Build]
    def initialize(build)
      @build = build
      @container_config = ContainerConfig.new

      container_config.distribution = build.template.distribution
      container_config.version = build.template.version
      container_config.arch = build.template.arch
      container_config.dataset = OsCtl::Lib::Zfs::Dataset.new(
        build.output_dataset,
        base: build.output_dataset,
      )
      container_config.rootfs = build.install_dir
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
      f.close
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
      f.close
    end
  end
end
