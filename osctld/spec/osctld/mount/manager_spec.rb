# frozen_string_literal: true

module OsCtld
  module Utils; end
end

require 'osctld/exceptions'
require 'osctld/mount/entry'
require 'osctld/utils/switch_user'
require 'osctld/mount/shared_dir'
require 'osctld/mount/manager'

RSpec.describe OsCtld::Mount::Manager do
  let(:pool) { build_fake_pool(root: Dir.mktmpdir('osctld-mount-manager')) }
  let(:ct) do
    FakeObjects::FakeRuntimeContainer.new(
      pool:,
      id: 'ct1',
      lxc_config: FakeObjects::FakeLxcConfig.new
    )
  end

  before do
    OsCtl::Lib::Logger.setup(:none)
    stub_const('OsCtld::ContainerControl', Module.new)
    stub_const('OsCtld::ContainerControl::Error', Class.new(StandardError))
    stub_const('OsCtld::ContainerControl::Commands', Module.new)
    stub_const('OsCtld::ContainerControl::Commands::Unmount', Class.new do
      def self.run!(*); end
    end)
    allow(OsCtld::ContainerControl::Commands::Unmount).to receive(:run!)
  end

  after do
    FileUtils.rm_rf(File.dirname(pool.mount_dir))
  end

  def entry(path, mountpoint, in_config: false, temp: false)
    OsCtld::Mount::Entry.new(path, mountpoint, 'bind', 'bind', true, in_config:, temp:)
  end

  it 'loads mounts from config' do
    manager = described_class.load(
      ct,
      [
        {
          'fs' => '/src',
          'mountpoint' => '/dst',
          'type' => 'bind',
          'opts' => 'bind',
          'automount' => true
        }
      ]
    )

    expect(manager.find_at('/dst').fs).to eq('/src')
  end

  it 'adds and registers mounts and persists configuration' do
    manager = described_class.new(ct)
    allow(manager.shared_dir).to receive(:propagate)
    ct.running = true
    added = entry('/src', '/dst')
    registered = entry('/src2', '/dst2')

    manager.add(added)
    manager.register(registered)

    expect(ct.save_config_calls).to eq(2)
    expect(ct.lxc_config.mount_calls).to eq(2)
    expect(manager.shared_dir).to have_received(:propagate).with(added)
    expect(manager.find_at('/dst2')).to eq(registered)
  end

  it 'deletes mounts and unmounts them for running containers' do
    manager = described_class.new(ct, entries: [entry('/src1', '/a'), entry('/src2', '/b')])
    ct.running = true

    manager.delete_at('/a')

    expect(manager.find_at('/a')).to be_nil
    expect(OsCtld::ContainerControl::Commands::Unmount).to have_received(:run!).with(ct, '/a')
    expect(ct.save_config_calls).to eq(1)
    expect(ct.lxc_config.mount_calls).to eq(1)
  end

  it 'persists cleared mounts and unmounts running entries in reverse order' do
    manager = described_class.new(ct, entries: [entry('/src1', '/a'), entry('/src2', '/b')])
    ct.running = true

    manager.clear

    expect(manager.to_a).to be_empty
    expect(OsCtld::ContainerControl::Commands::Unmount).to have_received(:run!).ordered.with(ct, '/b')
    expect(OsCtld::ContainerControl::Commands::Unmount).to have_received(:run!).ordered.with(ct, '/a')
    expect(ct.save_config_calls).to eq(1)
    expect(ct.lxc_config.mount_calls).to eq(1)
  end

  it 'does not unmount cleared mounts for stopped containers' do
    manager = described_class.new(ct, entries: [entry('/src1', '/a')])
    ct.running = false

    manager.clear

    expect(OsCtld::ContainerControl::Commands::Unmount).not_to have_received(:run!)
  end

  it 'exports mounts, shared helper entry, and duplicated managers' do
    configured = entry('/src1', '/a', in_config: true)
    auto = entry('/src2', '/b')
    temp = entry('/src3', '/c', temp: true)
    manager = described_class.new(ct, entries: [configured, auto, temp])
    allow(manager.shared_dir).to receive(:propagate)

    expect(manager.dump).to eq([configured.dump, auto.dump, temp.dump])
    entries = manager.all_entries
    expect(entries.map(&:mountpoint)).to include('dev/.osctl-mount-helper', '/sys/fs/bpf', '/a', '/b')
    expect(entries.map(&:mountpoint)).not_to include('/c')
    expect(entries.find { |entry| entry.mountpoint == '/sys/fs/bpf' }.fs)
      .to eq('/run/osctl/ct-bpf/tank/ct1')

    manager.activate('/b')
    expect(manager.shared_dir).to have_received(:propagate).with(auto)

    expect { manager.activate('/missing') }.to raise_error(OsCtld::MountNotFound)

    manager.deactivate('/b')
    expect(OsCtld::ContainerControl::Commands::Unmount).to have_received(:run!).with(ct, '/b')

    other_ct = FakeObjects::FakeRuntimeContainer.new(pool:, id: 'ct2')
    copy = manager.dup(other_ct)

    expect(copy.find_at('/a').fs).to eq('/src1')
    expect(copy.shared_dir.path).to eq(File.join(pool.mount_dir, 'ct2'))
  end
end
