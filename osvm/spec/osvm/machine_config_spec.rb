# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsVm::MachineConfig do
  describe '.load_file' do
    it 'parses json and delegates to from_config' do
      with_tmpdir do |dir|
        path = File.join(dir, 'machine.json')
        config_hash = machine_config_hash
        File.write(path, JSON.dump(config_hash))
        allow(described_class).to receive(:from_config).and_call_original

        config = described_class.load_file(path)

        expect(described_class).to have_received(:from_config).with(config_hash)
        expect(config).to be_a(OsVm::VpsadminosMachineConfig)
      end
    end
  end

  describe '.from_config' do
    it 'chooses the vpsadminos config class by default' do
      expect(described_class.from_config(machine_config_hash)).to be_a(OsVm::VpsadminosMachineConfig)
    end

    it 'chooses the nixos config class when requested' do
      expect(described_class.from_config(machine_config_hash({}, spin: 'nixos'))).to be_a(OsVm::NixosMachineConfig)
    end

    it 'raises on an unknown spin' do
      expect do
        described_class.from_config(machine_config_hash('spin' => 'unknown'))
      end.to raise_error(ArgumentError, /Unknown machine spin/)
    end
  end

  it 'requires kernel, initrd, and toplevel for direct boot machines' do
    %w[kernel initrd toplevel].each do |key|
      expect do
        build_machine_config({ key => nil })
      end.to raise_error(ArgumentError, /missing "#{key}" for direct boot machine/)
    end
  end

  it 'requires squashfs for direct vpsadminos machines' do
    expect do
      build_machine_config('squashfs' => nil)
    end.to raise_error(ArgumentError, /missing 'squashfs'/)
  end

  it 'requires diskImage for direct nixos machines' do
    expect do
      build_machine_config({ 'diskImage' => nil }, spin: 'nixos')
    end.to raise_error(ArgumentError, /missing 'diskImage'/)
  end

  it 'validates disk types' do
    expect do
      build_machine_config(
        'disks' => [{ 'device' => 'disk.img', 'type' => 'weird', 'size' => '1G' }]
      )
    end.to raise_error(ArgumentError, /unsupported disk type/)
  end

  it 'loads and validates test shell count' do
    expect(build_machine_config('testShells' => 3).test_shells).to eq(3)

    expect do
      build_machine_config('testShells' => 0)
    end.to raise_error(ArgumentError, /testShells must be an integer/)
  end

  it 'loads and validates named shells' do
    config = build_machine_config('testShells' => 3, 'shells' => %w[first second])

    expect(config.shell_names).to eq(%w[first second])

    expect do
      build_machine_config('shells' => [''])
    end.to raise_error(ArgumentError, /shells must be an array of non-empty strings/)

    expect do
      build_machine_config('shells' => %w[first first])
    end.to raise_error(ArgumentError, /shell names must be unique/)

    expect do
      build_machine_config('testShells' => 2, 'shells' => %w[first second])
    end.to raise_error(ArgumentError, /testShells must be greater than/)
  end

  it 'creates the correct network subclasses from config' do
    config = build_machine_config(
      'networks' => [
        { 'type' => 'user', 'mac' => '52:54:00:00:00:10' },
        { 'type' => 'socket', 'mac' => '52:54:00:00:00:11', 'mcast' => { 'port' => 12_345 } },
        { 'type' => 'bridge', 'mac' => '52:54:00:00:00:12', 'opts' => { 'link' => 'br0' } }
      ]
    )

    expect(config.networks.map(&:class)).to eq(
      [OsVm::MachineConfig::UserNetwork, OsVm::MachineConfig::SocketNetwork, OsVm::MachineConfig::BridgeNetwork]
    )
  end

  it 'rejects unknown network types' do
    expect do
      build_machine_config('networks' => [{ 'type' => 'bogus' }])
    end.to raise_error(ArgumentError, /unknown network type/)
  end

  it 'renders default user network qemu options' do
    network = build_machine_config('networks' => [{ 'type' => 'user', 'mac' => '52:54:00:00:00:10' }]).networks.first

    expect(network.qemu_options).to eq(
      [
        '-device', 'virtio-net,netdev=net0,mac=52:54:00:00:00:10',
        '-netdev', 'user,id=net0,net=10.0.2.0/24,host=10.0.2.2,dns=10.0.2.3'
      ]
    )
  end

  it 'reserves socket multicast ports from symbolic groups and accepts integers' do
    allow(OsVm::PortReservation).to receive(:get_port).with(key: 'mcast:group-a').and_return(12_345)

    symbolic = build_machine_config(
      'networks' => [{ 'type' => 'socket', 'mac' => '52:54:00:00:00:10', 'mcast' => { 'port' => 'group-a' } }]
    ).networks.first
    explicit = build_machine_config(
      'networks' => [{ 'type' => 'socket', 'mac' => '52:54:00:00:00:11', 'mcast' => { 'port' => 12_346 } }]
    ).networks.first

    expect(symbolic.mcast_port).to eq(12_345)
    expect(explicit.mcast_port).to eq(12_346)
  end

  it 'renders bridge qemu options' do
    network = build_machine_config(
      'networks' => [{ 'type' => 'bridge', 'mac' => '52:54:00:00:00:10', 'opts' => { 'link' => 'br0' } }]
    ).networks.first

    expect(network.qemu_options).to eq(
      [
        '-device', 'virtio-net,netdev=net0,mac=52:54:00:00:00:10',
        '-netdev', 'bridge,id=net0,br=br0'
      ]
    )
  end

  it 'uses explicit mac addresses and auto-generates missing ones' do
    allow(OsVm::MacAddressGenerator).to receive(:register_mac).and_call_original
    allow(OsVm::MacAddressGenerator).to receive(:next_mac).and_return('52:54:00:00:00:ff')

    config = build_machine_config(
      'networks' => [
        { 'type' => 'user', 'mac' => '52:54:00:00:00:10' },
        { 'type' => 'user' }
      ]
    )

    expect(config.networks[0].mac).to eq('52:54:00:00:00:10')
    expect(config.networks[1].mac).to eq('52:54:00:00:00:ff')
    expect(OsVm::MacAddressGenerator).to have_received(:register_mac).with('52:54:00:00:00:10')
  end

  it 'loads labels, tags, shared filesystems, and default networks' do
    config_hash = machine_config_hash
    config_hash.delete('networks')
    config = described_class.from_config(config_hash)

    expect(config.labels).to eq('role' => 'test')
    expect(config.tags).to eq(%w[smoke fast])
    expect(config.shared_filesystems).to eq('extra' => '/srv/extra')
    expect(config.networks.length).to eq(1)
    expect(config.networks.first).to be_a(OsVm::MachineConfig::UserNetwork)
  end
end
