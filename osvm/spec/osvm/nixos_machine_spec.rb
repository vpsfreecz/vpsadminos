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

  it 'refreshes the writable root image during disk preparation' do
    with_tmpdir do |dir|
      source_image = File.join(dir, 'source.img')
      File.write(source_image, 'fresh-image')
      config = build_machine_config({ 'diskImage' => source_image }, spin: 'nixos')
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
end
