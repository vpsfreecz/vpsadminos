# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::Operations::Image::Export do
  def build_double(tmpdir:, has_config_file: true)
    instance_double(
      OsCtl::Image::Operations::Image::Build,
      image_attrs: {
        distribution: 'alpine',
        version: '3.20',
        arch: 'x86_64',
        vendor: 'override-vendor',
        variant: 'minimal'
      },
      output_dataset: 'tank/build/output',
      install_dir: File.join(tmpdir, 'rootfs'),
      has_config_file?: has_config_file,
      read_config_file: { 'hostname' => 'test-vm' },
      output_tar: File.join(tmpdir, 'image-archive.tar'),
      output_stream: File.join(tmpdir, 'image-stream.tar')
    )
  end

  it 'builds a container config from the effective build attributes and exports both formats' do
    Dir.mktmpdir do |tmpdir|
      build = build_double(tmpdir:)
      op = described_class.new(build)
      order = []
      tar_exporter = Class.new do
        def initialize(order)
          @order = order
        end

        def dump_metadata(*)
          @order << :tar_metadata
        end

        def dump_configs
          @order << :tar_configs
        end

        def pack_rootfs
          @order << :tar_rootfs
        end
      end.new(order)
      zfs_exporter = Class.new do
        def initialize(order)
          @order = order
        end

        def dump_metadata(*)
          @order << :zfs_metadata
        end

        def dump_configs
          @order << :zfs_configs
        end

        def dump_base
          @order << :zfs_base
        end

        def dump_rootfs
          @order << :zfs_rootfs
          yield
        end
      end.new(order)

      FileUtils.mkdir_p(build.install_dir)
      allow(OsCtl::Lib::Exporter::Tar).to receive(:new) do |config, _io, compression:|
        expect(compression).to eq(:auto)
        expect(config.dump_config).to include(
          'distribution' => 'alpine',
          'version' => '3.20',
          'arch' => 'x86_64',
          'vendor' => 'override-vendor',
          'variant' => 'minimal',
          'hostname' => 'test-vm'
        )
        expect(config.dataset.name).to eq('tank/build/output')
        expect(config.dataset.base).to eq('tank/build/output')
        expect(config.rootfs).to eq(build.install_dir)
        tar_exporter
      end
      allow(OsCtl::Lib::Exporter::Zfs).to receive(:new) do |config, _io, compression:, compressed_send:|
        expect(compression).to eq(:gzip)
        expect(compressed_send).to be(false)
        expect(config.dump_config['vendor']).to eq('override-vendor')
        zfs_exporter
      end

      op.execute

      expect(order).to eq(
        %i[tar_metadata tar_configs tar_rootfs zfs_metadata zfs_configs zfs_rootfs zfs_base]
      )
    end
  end

  it 'always writes the stream export even when no archive is requested' do
    Dir.mktmpdir do |tmpdir|
      build = build_double(tmpdir:)
      op = described_class.new(build)
      zfs_exporter = instance_double(OsCtl::Lib::Exporter::Zfs)

      FileUtils.mkdir_p(build.install_dir)
      allow(build).to receive(:output_tar).and_return(nil)
      allow(OsCtl::Lib::Exporter::Tar).to receive(:new)
      allow(OsCtl::Lib::Exporter::Zfs).to receive(:new).and_return(zfs_exporter)
      allow(zfs_exporter).to receive(:dump_metadata)
      allow(zfs_exporter).to receive(:dump_configs)
      allow(zfs_exporter).to receive(:dump_base)
      allow(zfs_exporter).to receive(:dump_rootfs).and_yield

      op.execute

      expect(OsCtl::Lib::Exporter::Tar).not_to have_received(:new)
      expect(OsCtl::Lib::Exporter::Zfs).to have_received(:new)
    end
  end
end
