# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsVm::NixosMachine do
  it 'returns the systemd service check command' do
    with_tmpdir do |dir|
      machine = build_nixos_machine(dir:)

      expect(machine.send(:service_check_command, 'sshd')).to eq('systemctl is-active --quiet sshd')
    end
  end

  it 'uses poweroff for shutdown' do
    with_tmpdir do |dir|
      machine = build_nixos_machine(dir:)

      expect(machine.send(:poweroff_command)).to eq('poweroff')
    end
  end

  it 'adds the root image first and offsets extra disks' do
    with_tmpdir do |dir|
      config = build_machine_config(
        {
          'disks' => [{ 'device' => 'data.img', 'type' => 'file', 'size' => '1G' }]
        },
        spin: 'nixos'
      )
      machine = build_nixos_machine(dir:, config:)

      expect(machine.send(:qemu_disk_options)).to eq(
        [
          '-drive', "id=diskroot,file=#{File.join(dir, 'tmp', 'test-root.img')},if=none,format=raw",
          '-device', 'ide-hd,drive=diskroot,bus=ahci.0',
          '-drive', "id=disk1,file=#{File.join(dir, 'tmp', 'data.img')},if=none,format=raw",
          '-device', 'ide-hd,drive=disk1,bus=ahci.1'
        ]
      )
    end
  end

  it 'refreshes a root disk with preserve=false during disk preparation' do
    with_tmpdir do |dir|
      source_image = File.join(dir, 'source.img')
      File.write(source_image, 'fresh-image')
      config = build_machine_config({ 'diskImage' => nil, 'rootDisk' => { 'device' => '{machine}-root.img', 'type' => 'file', 'image' => source_image, 'preserve' => false } }, spin: 'nixos')
      machine = build_nixos_machine(dir:, config:)
      root_disk = machine.send(:root_disk_path)

      File.write(root_disk, 'stale-image')

      machine.send(:prepare_disks)

      expect(File.read(root_disk)).to eq('fresh-image')
    end
  end

  it 'removes the root image and extra file-backed disks on destroy' do
    with_tmpdir do |dir|
      source_image = File.join(dir, 'source.img')
      File.write(source_image, 'fresh-image')
      config = build_machine_config(
        {
          'diskImage' => source_image,
          'disks' => [{ 'device' => 'data.img', 'type' => 'file', 'size' => '1G' }]
        },
        spin: 'nixos'
      )
      machine = build_nixos_machine(dir:, config:)
      root_disk = machine.send(:root_disk_path)
      data_disk = File.join(dir, 'tmp', 'data.img')

      File.write(root_disk, 'root')
      File.write(data_disk, 'data')

      machine.destroy_disks

      expect(File.exist?(root_disk)).to be(false)
      expect(File.exist?(data_disk)).to be(false)
    end
  end

  it 'keeps root data across preparations by default' do
    with_tmpdir do |dir|
      source_image = File.join(dir, 'source.img')
      File.write(source_image, 'fresh-image')
      config = build_machine_config({ 'diskImage' => source_image }, spin: 'nixos')
      machine = build_nixos_machine(dir:, config:)
      root_disk = machine.send(:root_disk_path)

      machine.send(:prepare_disks)
      expect(File.read(root_disk)).to eq('fresh-image')
      File.write(root_disk, 'retained-data')
      File.write(source_image, 'changed-image')

      restarted_machine = build_nixos_machine(dir:, config:)
      restarted_machine.send(:prepare_disks)
      expect(File.read(root_disk)).to eq('retained-data')

      restarted_machine.destroy_disks
      restarted_machine.send(:prepare_disks)
      expect(File.read(root_disk)).to eq('changed-image')
    end
  end

  it 'still prepares additional disks when retaining the root disk' do
    with_tmpdir do |dir|
      config = build_machine_config(
        { 'disks' => [{ 'device' => 'data.img', 'type' => 'file', 'size' => '1M' }] },
        spin: 'nixos'
      )
      machine = build_nixos_machine(dir:, config:)
      File.write(machine.send(:root_disk_path), 'retained-data')

      machine.send(:prepare_disks)

      expect(File.read(machine.send(:root_disk_path))).to eq('retained-data')
      expect(File.size(File.join(dir, 'tmp', 'data.img'))).to eq(1024 * 1024)
    end
  end

  it 'does not publish a partial root disk when copying fails' do
    with_tmpdir do |dir|
      machine = build_nixos_machine(dir:)
      allow(FileUtils).to receive(:cp) do |_source, destination|
        File.write(destination, 'partial-image')
        raise IOError, 'copy failed'
      end

      expect { machine.send(:prepare_disks) }.to raise_error(IOError, 'copy failed')
      expect(File.exist?(machine.send(:root_disk_path))).to be(false)
      expect(Dir.glob(File.join(dir, 'tmp', 'osvm-disk-*'))).to be_empty
    end
  end
end
