# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::Operations::Test::Run do
  def build_double(image:, tmpdir:)
    stream_path = File.join(tmpdir, 'image-stream.tar')
    archive_path = File.join(tmpdir, 'image-archive.tar')
    File.write(stream_path, '')

    instance_double(
      OsCtl::Image::Operations::Image::Build,
      image: image,
      output_stream: stream_path,
      output_tar: archive_path
    )
  end

  def stable_run_class
    Class.new(described_class) do
      def log(*)
        nil
      end

      def sleep(*)
        nil
      end

      def gen_ctid
        'test-ct'
      end
    end
  end

  def stub_client(client)
    allow(client).to receive(:create_container_from_file)
    allow(client).to receive(:unset_container_start_menu)
    allow(client).to receive(:set_container_attr)
    allow(client).to receive(:kill_container)
    allow(client).to receive(:delete_container)
  end

  def new_operation(build:, test_case:, client:, ip_allocator:, keep_failed: false, klass: described_class)
    allow(OsCtl::Image::OsCtldClient).to receive(:new).and_return(client)
    klass.new('/scripts', build, test_case, keep_failed:, ip_allocator:)
  end

  it 'imports the built image, tags it, runs the test and cleans up on success' do
    Dir.mktmpdir do |tmpdir|
      image = instance_double(OsCtl::Image::Image, name: 'alpine-3.20')
      build = build_double(image:, tmpdir:)
      test_case = instance_double(OsCtl::Image::Test, name: 'smoke', to_s: 'smoke')
      client = instance_double(OsCtl::Image::OsCtldClient)
      ip_allocator = instance_double(OsCtl::Image::IpAllocator)
      ip = IPAddress.parse('10.100.10.2')
      op = new_operation(
        build:,
        test_case:,
        client:,
        ip_allocator:,
        klass: stable_run_class
      )

      stub_client(client)
      allow(ip_allocator).to receive(:get).and_return(ip)
      allow(ip_allocator).to receive(:put)
      allow(OsCtl::Image::Operations::Nix::RunInShell).to receive(:run).and_return(command_result)

      status = op.execute

      expect(status).to have_attributes(success?: true, exitstatus: 0, output: nil)
      expect(client).to have_received(:create_container_from_file).with(
        'test-ct',
        File.join(tmpdir, 'image-stream.tar')
      )
      expect(client).to have_received(:set_container_attr).with(
        'test-ct',
        'org.vpsadminos.osctl-image:type',
        'test'
      )
      expect(OsCtl::Image::Operations::Nix::RunInShell).to have_received(:run).with(
        '/scripts/shell-test-flake.nix',
        ['/scripts/bin/test', 'image', 'run', 'alpine-3.20', 'smoke', 'test-ct'],
        env: hash_including('OSCTL_IMAGE_TEST_IPV4_ADDRESS' => '10.100.10.2')
      )
      expect(ip_allocator).to have_received(:put).with(ip)
      expect(client).to have_received(:kill_container).with('test-ct')
      expect(client).to have_received(:delete_container).with('test-ct', prune: true)
    end
  end

  it 'returns a failed status on SystemCommandFailed and cleans up by default' do
    Dir.mktmpdir do |tmpdir|
      image = instance_double(OsCtl::Image::Image, name: 'alpine-3.20')
      build = build_double(image:, tmpdir:)
      test_case = instance_double(OsCtl::Image::Test, name: 'smoke', to_s: 'smoke')
      client = instance_double(OsCtl::Image::OsCtldClient)
      ip_allocator = instance_double(OsCtl::Image::IpAllocator)
      ip = IPAddress.parse('10.100.10.2')
      op = new_operation(
        build:,
        test_case:,
        client:,
        ip_allocator:,
        klass: stable_run_class
      )

      stub_client(client)
      allow(ip_allocator).to receive(:get).and_return(ip)
      allow(ip_allocator).to receive(:put)
      allow(OsCtl::Image::Operations::Nix::RunInShell).to receive(:run)
        .and_raise(OsCtl::Lib::Exceptions::SystemCommandFailed.new('cmd', 2, 'boom'))

      status = op.execute

      expect(status).to have_attributes(success?: false, exitstatus: 2, output: 'boom')
      expect(client).to have_received(:delete_container).with('test-ct', prune: true)
    end
  end

  it 'preserves failed containers when keep_failed is enabled' do
    Dir.mktmpdir do |tmpdir|
      image = instance_double(OsCtl::Image::Image, name: 'alpine-3.20')
      build = build_double(image:, tmpdir:)
      test_case = instance_double(OsCtl::Image::Test, name: 'smoke', to_s: 'smoke')
      client = instance_double(OsCtl::Image::OsCtldClient)
      ip_allocator = instance_double(OsCtl::Image::IpAllocator)
      ip = IPAddress.parse('10.100.10.2')
      cmd = new_operation(
        build:,
        test_case:,
        client:,
        ip_allocator:,
        keep_failed: true,
        klass: stable_run_class
      )

      stub_client(client)
      allow(ip_allocator).to receive(:get).and_return(ip)
      allow(ip_allocator).to receive(:put)
      allow(OsCtl::Image::Operations::Nix::RunInShell).to receive(:run)
        .and_raise(OsCtl::Lib::Exceptions::SystemCommandFailed.new('cmd', 2, 'boom'))

      cmd.execute

      expect(client).not_to have_received(:delete_container)
    end
  end

  it 'does not mask IP allocation failures during cleanup' do
    Dir.mktmpdir do |tmpdir|
      image = instance_double(OsCtl::Image::Image, name: 'alpine-3.20')
      build = build_double(image:, tmpdir:)
      test_case = instance_double(OsCtl::Image::Test, name: 'smoke', to_s: 'smoke')
      client = instance_double(OsCtl::Image::OsCtldClient)
      ip_allocator = instance_double(OsCtl::Image::IpAllocator)
      op = new_operation(
        build:,
        test_case:,
        client:,
        ip_allocator:,
        klass: stable_run_class
      )

      stub_client(client)
      allow(ip_allocator).to receive(:get).and_raise(RuntimeError, 'boom')
      allow(ip_allocator).to receive(:put)

      expect { op.execute }.to raise_error(RuntimeError, 'boom')
      expect(ip_allocator).not_to have_received(:put)
    end
  end

  it 'does not mask unexpected test errors during cleanup' do
    Dir.mktmpdir do |tmpdir|
      image = instance_double(OsCtl::Image::Image, name: 'alpine-3.20')
      build = build_double(image:, tmpdir:)
      test_case = instance_double(OsCtl::Image::Test, name: 'smoke', to_s: 'smoke')
      client = instance_double(OsCtl::Image::OsCtldClient)
      ip_allocator = instance_double(OsCtl::Image::IpAllocator)
      ip = IPAddress.parse('10.100.10.2')
      op = new_operation(
        build:,
        test_case:,
        client:,
        ip_allocator:,
        klass: stable_run_class
      )

      stub_client(client)
      allow(ip_allocator).to receive(:get).and_return(ip)
      allow(ip_allocator).to receive(:put)
      allow(OsCtl::Image::Operations::Nix::RunInShell).to receive(:run)
        .and_raise(RuntimeError, 'boom')

      expect { op.execute }.to raise_error(RuntimeError, 'boom')
      expect(ip_allocator).to have_received(:put).with(ip)
    end
  end
end
