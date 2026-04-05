# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::Operations::Image::Build do
  def build_image(datasets: {})
    instance_double(
      OsCtl::Image::Image,
      load_config: nil,
      builder: 'default-builder',
      distribution: 'alpine',
      version: '3.20',
      arch: 'x86_64',
      vendor: 'source-vendor',
      variant: 'minimal',
      datasets: datasets,
      name: 'alpine-3.20-x86_64-source-vendor-minimal'
    )
  end

  def build_builder(rootfs:)
    instance_double(
      OsCtl::Image::Builder,
      load_config: nil,
      name: 'default-builder',
      ctid: 'builder-1',
      attrs: { rootfs: rootfs, group_path: 'group' }
    )
  end

  def build_opts(vendor: 'override-vendor', vpsadminos_dir: '/repo')
    {
      build_dataset: 'tank/builds',
      output_dir: '/exports',
      vendor:,
      vpsadminos_dir: vpsadminos_dir
    }
  end

  def new_build(image:, builder:, client:, opts:, klass: described_class)
    allow(SecureRandom).to receive(:hex).with(4).and_return('beef')
    allow(OsCtl::Image::Builder).to receive(:new).with('/scripts', 'default-builder').and_return(builder)
    allow(OsCtl::Image::OsCtldClient).to receive(:new).and_return(client)
    allow(client).to receive(:batch).and_yield
    klass.new('/scripts', image, opts)
  end

  it 'derives dataset names and output paths during initialization' do
    Dir.mktmpdir do |tmpdir|
      image = build_image
      builder = build_builder(rootfs: File.join(tmpdir, 'rootfs'))
      client = instance_double(OsCtl::Image::OsCtldClient)
      build = new_build(image:, builder:, client:, opts: build_opts)

      expect(build.output_dataset).to eq('tank/builds/beef/output')
      expect(build.work_dataset).to eq('tank/builds/beef/work')
      expect(build.output_tar).to eq('/exports/alpine-3.20-x86_64-override-vendor-minimal-archive.tar')
      expect(build.output_stream).to eq('/exports/alpine-3.20-x86_64-override-vendor-minimal-stream.tar')
    end
  end

  it 'exposes a single source of truth for effective image attributes' do
    Dir.mktmpdir do |tmpdir|
      image = build_image
      builder = build_builder(rootfs: File.join(tmpdir, 'rootfs'))
      client = instance_double(OsCtl::Image::OsCtldClient)
      build = new_build(image:, builder:, client:, opts: build_opts)

      expect(build.effective_vendor).to eq('override-vendor')
      expect(build.image_attrs).to eq(
        distribution: 'alpine',
        version: '3.20',
        arch: 'x86_64',
        vendor: 'override-vendor',
        variant: 'minimal'
      )
    end
  end

  it 'reports cached outputs when either stream or archive exists' do
    Dir.mktmpdir do |tmpdir|
      image = build_image
      builder = build_builder(rootfs: File.join(tmpdir, 'rootfs'))
      client = instance_double(OsCtl::Image::OsCtldClient)
      build = new_build(image:, builder:, client:, opts: build_opts)

      allow(File).to receive(:exist?).with(build.output_tar).and_return(false)
      allow(File).to receive(:exist?).with(build.output_stream).and_return(true)

      expect(build.cached?).to be(true)
    end
  end

  it 'checks for and reads the build config file' do
    Dir.mktmpdir do |tmpdir|
      image = build_image
      builder = build_builder(rootfs: File.join(tmpdir, 'rootfs'))
      client = instance_double(OsCtl::Image::OsCtldClient)
      build = new_build(image:, builder:, client:, opts: build_opts)
      config_path = File.join(tmpdir, 'container.yml')

      File.write(config_path, "hostname: test\n")
      build.instance_variable_set(:@config_file, config_path)
      allow(OsCtl::Lib::ConfigFile).to receive(:load_yaml_file)
        .with(config_path)
        .and_return('hostname' => 'test')

      expect(build.has_config_file?).to be(true)
      expect(build.read_config_file).to eq('hostname' => 'test')
      expect(File.exist?(config_path)).to be(false)
    end
  end

  it 'returns itself from execute' do
    execute_class = Class.new(described_class) do
      attr_reader :call_order

      def initialize(*args)
        super
        @call_order = []
      end

      def build
        @call_order << :build
      end

      def cleanup
        @call_order << :cleanup
      end

      def log(*)
        nil
      end
    end

    Dir.mktmpdir do |tmpdir|
      image = build_image
      builder = build_builder(rootfs: File.join(tmpdir, 'rootfs'))
      client = instance_double(OsCtl::Image::OsCtldClient)
      build = new_build(
        image:,
        builder:,
        client:,
        opts: build_opts,
        klass: execute_class
      )

      expect(build.execute).to be(build)
      expect(build.call_order).to eq(%i[build cleanup])
    end
  end

  context 'with image datasets' do
    it 'runs the build flow and exports the built image' do
      build_class = Class.new(described_class) do
        attr_writer :zfs_handler

        def zfs(*args, **kwargs)
          @zfs_handler.call(*args, **kwargs)
        end
      end

      Dir.mktmpdir do |tmpdir|
        image = build_image(
          datasets: {
            'var' => '/var',
            'var/log' => '/var/log'
          }
        )
        rootfs = File.join(tmpdir, 'rootfs')
        work_mount = File.join(tmpdir, 'work')
        output_mount = File.join(tmpdir, 'output')
        builder = build_builder(rootfs:)
        client = instance_double(OsCtl::Image::OsCtldClient)
        build = new_build(
          image:,
          builder:,
          client:,
          opts: build_opts,
          klass: build_class
        )

        FileUtils.mkdir_p(rootfs)
        FileUtils.mkdir_p(work_mount)
        FileUtils.mkdir_p(File.join(output_mount, 'var', 'log'))
        allow(client).to receive(:bind_mount)
        allow(client).to receive(:activate_mount)
        allow(OsCtl::Image::Operations::Builder::UseOrCreate).to receive(:run)
        allow(OsCtl::Image::Operations::Builder::GetRootUgid).to receive(:run).and_return([100_000, 100_000])
        allow(OsCtl::Image::Operations::Builder::ControlledExec).to receive(:run).and_return(0)
        allow(OsCtl::Image::Operations::Image::FixFileCapabilities).to receive(:run)
        allow(OsCtl::Image::Operations::Image::Export).to receive(:run)
        sys = instance_double(OsCtl::Lib::Sys, syncfs: nil)
        allow(OsCtl::Lib::Sys).to receive(:new).and_return(sys)
        build.zfs_handler = lambda do |action, _options, dataset, **_kwargs|
          case [action, dataset]
          when [:get, build.work_dataset]
            command_result("#{work_mount}\n")
          when [:get, build.output_dataset]
            command_result("#{output_mount}\n")
          when [:list, build.output_dataset]
            command_result('', exitstatus: 1)
          else
            command_result
          end
        end

        build.send(:build)

        expect(OsCtl::Image::Operations::Builder::UseOrCreate).to have_received(:run).with(
          builder,
          '/scripts',
          vpsadminos_dir: '/repo'
        )
        expect(OsCtl::Image::Operations::Builder::GetRootUgid).to have_received(:run).with(builder)
        expect(client).to have_received(:bind_mount).with(
          'builder-1',
          '/scripts',
          build.send(:builder_base_dir),
          map_ids: false
        )
        expect(client).to have_received(:bind_mount).with(
          'builder-1',
          work_mount,
          build.send(:builder_work_dir)
        )
        expect(client).to have_received(:bind_mount).with(
          'builder-1',
          File.join(output_mount, 'private'),
          build.send(:builder_install_dir)
        )
        expect(client).to have_received(:bind_mount).with(
          'builder-1',
          '/repo',
          build.send(:builder_vpsadminos_dir),
          map_ids: false
        )
        expect(client).to have_received(:activate_mount).with(
          'builder-1',
          File.join(build.send(:builder_install_dir), '/var')
        )
        expect(client).to have_received(:activate_mount).with(
          'builder-1',
          File.join(build.send(:builder_install_dir), '/var/log')
        )
        expect(OsCtl::Image::Operations::Builder::ControlledExec).to have_received(:run).with(
          builder,
          [
            File.join(build.send(:builder_base_dir), 'bin', 'runner'),
            'image',
            'build',
            'beef',
            build.send(:builder_work_dir),
            build.send(:builder_install_dir),
            image.name
          ],
          id: 'beef',
          client: client,
          env: { 'OSCTL_IMAGE_VPSADMINOS_DIR' => build.send(:builder_vpsadminos_dir) }
        )
        expect(sys).to have_received(:syncfs).with(File.join(output_mount, 'private'))
        expect(OsCtl::Image::Operations::Image::FixFileCapabilities).to have_received(:run).with(
          image,
          File.join(output_mount, 'private')
        )
        expect(OsCtl::Image::Operations::Image::Export).to have_received(:run).with(build)
      end
    end

    it 'cleans up mounts, temporary directories and datasets' do
      build_class = Class.new(described_class) do
        attr_accessor :zfs_handler
        attr_reader :zfs_calls

        def zfs(*args, **kwargs)
          @zfs_calls ||= []
          @zfs_calls << [args[0], args[1], args[2], kwargs]
          zfs_handler.call(*args, **kwargs)
        end
      end

      Dir.mktmpdir do |tmpdir|
        image = build_image(
          datasets: {
            'var' => '/var',
            'var/log' => '/var/log'
          }
        )
        rootfs = File.join(tmpdir, 'rootfs')
        builder = build_builder(rootfs:)
        client = instance_double(OsCtl::Image::OsCtldClient)
        build = new_build(
          image:,
          builder:,
          client:,
          opts: build_opts,
          klass: build_class
        )

        FileUtils.mkdir_p(rootfs)
        build.instance_variable_set(:@work_dir, File.join(tmpdir, 'work'))
        build.instance_variable_set(:@output_dir, File.join(tmpdir, 'output'))
        build.instance_variable_set(:@install_dir, File.join(tmpdir, 'output', 'private'))

        [
          build.send(:builder_base_dir),
          build.send(:builder_work_dir),
          build.send(:builder_install_dir),
          build.send(:builder_vpsadminos_dir)
        ].each do |dir|
          FileUtils.mkdir_p(File.join(rootfs, dir))
        end

        allow(client).to receive(:ignore_error).and_yield
        unmounts = []
        allow(client).to receive(:unmount) do |_ctid, mountpoint|
          unmounts << mountpoint
        end
        build.zfs_handler = lambda do |action, _options, _dataset, **_kwargs|
          if action == :list
            command_result("#{build.output_dataset}@snap2\n#{build.output_dataset}@snap1\n")
          else
            command_result
          end
        end

        build.send(:cleanup)

        expect(unmounts).to eq(
          [
            build.send(:builder_work_dir),
            build.send(:builder_vpsadminos_dir),
            File.join(build.send(:builder_install_dir), '/var/log'),
            File.join(build.send(:builder_install_dir), '/var'),
            build.send(:builder_install_dir),
            build.send(:builder_base_dir)
          ]
        )
        expect(File.exist?(File.join(rootfs, build.send(:builder_base_dir)))).to be(false)
        expect(File.exist?(File.join(rootfs, build.send(:builder_work_dir)))).to be(false)
        expect(File.exist?(File.join(rootfs, build.send(:builder_install_dir)))).to be(false)
        expect(File.exist?(File.join(rootfs, build.send(:builder_vpsadminos_dir)))).to be(false)

        snapshot_destroy_index = build.zfs_calls.index([:destroy, nil, "#{build.output_dataset}@snap2", {}])
        output_destroy_index = build.zfs_calls.index(
          [:destroy, '-r', build.output_dataset, { valid_rcs: :all }]
        )
        expect(snapshot_destroy_index).to be < output_destroy_index
        expect(build.zfs_calls).to include(
          [:destroy, nil, build.send(:build_dataset), { valid_rcs: :all }]
        )
      end
    end
  end
end
