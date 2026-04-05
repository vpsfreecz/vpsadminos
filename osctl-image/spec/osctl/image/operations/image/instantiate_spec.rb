# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::Operations::Image::Instantiate do
  def build_opts(rebuild: false, ctid: nil)
    {
      build_dataset: 'tank/builds',
      output_dir: '/output',
      rebuild: rebuild,
      ctid: ctid
    }
  end

  def new_operation(image:, client:, opts:, klass: described_class)
    allow(OsCtl::Image::OsCtldClient).to receive(:new).and_return(client)
    klass.new('/scripts', image, opts)
  end

  it 'executes the build once when rebuild is requested' do
    image = instance_double(OsCtl::Image::Image)
    client = instance_double(OsCtl::Image::OsCtldClient)
    build = instance_double(
      OsCtl::Image::Operations::Image::Build,
      execute: nil,
      output_stream: '/tmp/stream',
      output_tar: '/tmp/tar',
      image: image
    )
    test_class = Class.new(described_class) do
      attr_reader :instantiated_build

      def instantiate(build)
        @instantiated_build = build
      end
    end

    allow(OsCtl::Image::Operations::Image::Build).to receive(:new).and_return(build)
    cmd = new_operation(
      image:,
      client:,
      opts: build_opts(rebuild: true),
      klass: test_class
    )

    cmd.execute

    expect(build).to have_received(:execute).once
    expect(cmd.instantiated_build).to eq(build)
  end

  it 'does not rebuild when cached artifacts already exist' do
    image = instance_double(OsCtl::Image::Image)
    client = instance_double(OsCtl::Image::OsCtldClient)

    Dir.mktmpdir do |dir|
      stream = File.join(dir, 'image-stream.tar')
      File.write(stream, '')
      build = instance_double(
        OsCtl::Image::Operations::Image::Build,
        execute: nil,
        output_stream: stream,
        output_tar: File.join(dir, 'image-archive.tar')
      )
      test_class = Class.new(described_class) do
        attr_reader :instantiated_build

        def instantiate(build)
          @instantiated_build = build
        end
      end

      allow(OsCtl::Image::Operations::Image::Build).to receive(:new).and_return(build)
      op = new_operation(image:, client:, opts: build_opts, klass: test_class)

      op.execute

      expect(build).not_to have_received(:execute)
      expect(op.instantiated_build).to eq(build)
    end
  end

  it 'builds when cached artifacts are missing' do
    image = instance_double(OsCtl::Image::Image)
    client = instance_double(OsCtl::Image::OsCtldClient)
    build = instance_double(
      OsCtl::Image::Operations::Image::Build,
      execute: nil,
      output_stream: '/tmp/missing-stream.tar',
      output_tar: '/tmp/missing-archive.tar'
    )
    test_class = Class.new(described_class) do
      attr_reader :instantiated_build

      def instantiate(build)
        @instantiated_build = build
      end
    end

    allow(OsCtl::Image::Operations::Image::Build).to receive(:new).and_return(build)
    op = new_operation(image:, client:, opts: build_opts, klass: test_class)

    op.execute

    expect(build).to have_received(:execute).once
    expect(op.instantiated_build).to eq(build)
  end

  it 'reinstalls an existing container when a ctid is provided' do
    image = instance_double(OsCtl::Image::Image)
    client = instance_double(OsCtl::Image::OsCtldClient)

    allow(client).to receive(:stop_container)
    allow(client).to receive(:reinstall_container_from_image)

    new_operation(image:, client:, opts: build_opts(ctid: 'ct1')).send(:create_container, '/tmp/image')

    expect(client).to have_received(:stop_container).with('ct1')
    expect(client).to have_received(:reinstall_container_from_image).with(
      'ct1',
      '/tmp/image',
      remove_snapshots: true
    )
  end

  it 'imports a new container and tags it as an instance when no ctid is provided' do
    image = instance_double(OsCtl::Image::Image)
    client = instance_double(OsCtl::Image::OsCtldClient)
    test_class = Class.new(described_class) do
      def sleep(*)
        nil
      end
    end

    allow(SecureRandom).to receive(:hex).with(4).and_return('1')
    cmd = new_operation(image:, client:, opts: build_opts, klass: test_class)
    allow(client).to receive(:create_container_from_file)
    allow(client).to receive(:set_container_attr)

    cmd.send(:create_container, '/tmp/image')

    expect(client).to have_received(:create_container_from_file).with('instance-1', '/tmp/image')
    expect(client).to have_received(:set_container_attr).with(
      'instance-1',
      'org.vpsadminos.osctl-image:type',
      'instance'
    )
  end

  it 'prefers stream output over archive output when instantiating' do
    image = instance_double(OsCtl::Image::Image)
    client = instance_double(OsCtl::Image::OsCtldClient)
    test_class = Class.new(described_class) do
      attr_reader :created_path

      def create_container(path)
        @created_path = path
      end
    end

    Dir.mktmpdir do |dir|
      stream = File.join(dir, 'image-stream.tar')
      archive = File.join(dir, 'image-archive.tar')
      File.write(stream, '')
      File.write(archive, '')
      build = instance_double(OsCtl::Image::Operations::Image::Build, output_stream: stream, output_tar: archive, image: image)
      op = new_operation(image:, client:, opts: build_opts, klass: test_class)

      op.send(:instantiate, build)

      expect(op.created_path).to eq(stream)
    end
  end

  it 'falls back to archive output when no stream exists' do
    image = instance_double(OsCtl::Image::Image)
    client = instance_double(OsCtl::Image::OsCtldClient)
    test_class = Class.new(described_class) do
      attr_reader :created_path

      def create_container(path)
        @created_path = path
      end
    end

    Dir.mktmpdir do |dir|
      archive = File.join(dir, 'image-archive.tar')
      File.write(archive, '')
      build = instance_double(OsCtl::Image::Operations::Image::Build, output_stream: File.join(dir, 'missing-stream.tar'), output_tar: archive, image: image)
      op = new_operation(image:, client:, opts: build_opts, klass: test_class)

      op.send(:instantiate, build)

      expect(op.created_path).to eq(archive)
    end
  end

  it 'raises when neither output artifact exists' do
    image = instance_double(OsCtl::Image::Image)
    client = instance_double(OsCtl::Image::OsCtldClient)
    build = instance_double(
      OsCtl::Image::Operations::Image::Build,
      output_stream: '/tmp/missing-stream.tar',
      output_tar: '/tmp/missing-archive.tar',
      image: image
    )
    op = new_operation(image:, client:, opts: build_opts)

    expect { op.send(:instantiate, build) }
      .to raise_error(OsCtl::Image::OperationError, "no image file for '#{image}' found in output directory")
  end
end
