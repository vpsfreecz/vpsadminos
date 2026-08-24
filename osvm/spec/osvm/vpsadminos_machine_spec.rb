# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsVm::VpsadminosMachine do
  it 'parses osctl json output' do
    with_tmpdir do |dir|
      machine = build_vpsadminos_machine(dir:)
      allow(machine).to receive(:succeeds).with('osctl -j pool ls').and_return([0, '{"state":"active"}'])

      expect(machine.osctl_json('pool ls')).to eq('state' => 'active')
    end
  end

  it 'waits for zpools by delegating to wait_until_succeeds' do
    with_tmpdir do |dir|
      machine = build_vpsadminos_machine(dir:)
      allow(machine).to receive(:wait_until_succeeds).and_return([0, ''])

      expect(machine.wait_for_zpool('tank', timeout: 12)).to eq(machine)
      expect(machine).to have_received(:wait_until_succeeds).with('zpool list tank', timeout: 12)
    end
  end

  it 'waits for osctl pools to become active' do
    with_tmpdir do |dir|
      machine = build_vpsadminos_machine(dir:)
      allow(machine).to receive(:execute).and_return([0, "importing\n"], [0, "active\n"])
      allow(machine).to receive(:sleep)

      expect(machine.wait_for_osctl_pool('tank', timeout: 20)).to eq(machine)
      expect(machine).to have_received(:execute).with(
        'osctl pool show -H -o state tank',
        timeout: 10
      ).twice
    end
  end

  it 'retries timed out osctl pool probes' do
    with_tmpdir do |dir|
      machine = build_vpsadminos_machine(dir:)
      calls = 0
      allow(machine).to receive(:execute) do
        calls += 1
        raise OsVm::TimeoutError, 'timed out' if calls == 1

        [0, "active\n"]
      end
      allow(machine).to receive(:sleep)

      expect(machine.wait_for_osctl_pool('tank', timeout: 20)).to eq(machine)
      expect(machine).to have_received(:execute).with(
        'osctl pool show -H -o state tank',
        timeout: 10
      ).twice
    end
  end

  it 'times out while waiting for an osctl pool to become active' do
    with_tmpdir do |dir|
      machine = build_vpsadminos_machine(dir:)
      allow(machine).to receive(:execute).and_return([0, "importing\n"])

      expect do
        machine.wait_for_osctl_pool('tank', timeout: 0)
      end.to raise_error(OsVm::TimeoutError, /waiting for pool "tank" to become active/)
    end
  end

  it 'waits for osctl containers to reach the requested state' do
    with_tmpdir do |dir|
      machine = build_vpsadminos_machine(dir:)
      allow(machine).to receive(:wait_until_succeeds).and_return([0, "stopped\n"], [0, "running\n"])
      allow(machine).to receive(:sleep)

      expect(machine.wait_for_osctl_container('ct1')).to eq(machine)
      expect(machine).to have_received(:wait_until_succeeds)
        .with('osctl ct show -H -o runtime_state ct1', timeout: kind_of(Numeric))
        .twice
    end
  end

  it 'times out while waiting for an osctl container state' do
    with_tmpdir do |dir|
      machine = build_vpsadminos_machine(dir:)
      allow(machine).to receive(:wait_until_succeeds).and_return([0, "stopped\n"])

      expect do
        machine.wait_for_osctl_container('ct1', timeout: 0)
      end.to raise_error(OsVm::TimeoutError, /waiting for container "ct1" to become running/)
    end
  end

  it 'waits for containers to become online through osctl ct exec' do
    with_tmpdir do |dir|
      machine = build_vpsadminos_machine(dir:)
      allow(machine).to receive(:wait_until_succeeds).and_return([0, ''])

      expect(machine.wait_until_container_online('ct1', timeout: 12)).to eq(machine)
      expect(machine).to have_received(:wait_until_succeeds).with(
        "osctl ct exec ct1 sh -c 'ping -c 1 check-online.vpsadminos.org || curl --head https://check-online.vpsadminos.org || wget -O - https://check-online.vpsadminos.org || getent hosts check-online.vpsadminos.org'",
        timeout: 12
      )
    end
  end

  it 'includes squashfs boot media only when configured' do
    with_tmpdir do |dir|
      machine = build_vpsadminos_machine(dir:)
      no_media_machine = build_vpsadminos_machine(
        dir:,
        config: build_machine_config(
          {
            'bootMode' => 'firmware',
            'bootOrder' => 'dc',
            'kernel' => nil,
            'initrd' => nil,
            'toplevel' => nil,
            'squashfs' => nil,
            'networks' => [{ 'type' => 'user', 'mac' => '52:54:00:00:00:20' }]
          }
        )
      )

      expect(machine.send(:qemu_boot_media_options)).to include(
        '-drive',
        'index=0,id=drive1,file=/images/system.squashfs,readonly=on,media=cdrom,format=raw,if=virtio'
      )
      expect(no_media_machine.send(:qemu_boot_media_options)).to eq([])
    end
  end

  it 'builds qemu commands with boot media and shared options' do
    with_tmpdir do |dir|
      machine = build_vpsadminos_machine(dir:, config: build_machine_config('iso' => '/images/install.iso'))

      command = machine.send(:qemu_command, kernel_params: ['debug'])

      expect(command).to include('/nix/store/qemu/bin/qemu-kvm')
      expect(command).to include('-cdrom', '/images/install.iso')
      expect(command).to include('-drive', 'index=0,id=drive1,file=/images/system.squashfs,readonly=on,media=cdrom,format=raw,if=virtio')
      expect(command.grep(/path=.*shell\.sock/).first).not_to be_nil
      expect(command.grep(/tag=vmSharedDir/).first).not_to be_nil
    end
  end
end
