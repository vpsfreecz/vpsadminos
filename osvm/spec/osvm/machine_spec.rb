# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsVm::Machine do
  it 'creates tmp and socket directories and adds the default shared filesystem' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)

      expect(File.directory?(File.join(dir, 'tmp'))).to be(true)
      expect(File.directory?(File.join(dir, 'sock'))).to be(true)
      expect(machine.send(:shared_filesystems)).to include(
        'vmSharedDir' => File.join(dir, 'tmp', 'shared-dir'),
        'extra' => '/srv/extra'
      )
    end
  end

  it 'resolves disk paths for machine placeholders and absolute paths' do
    with_tmpdir do |dir|
      machine = build_machine(dir:, name: 'alpha')

      expect(machine.send(:disk_path, '{machine}-disk.img')).to eq(File.join(dir, 'tmp', 'alpha-disk.img'))
      expect(machine.send(:disk_path, '/var/lib/data.img')).to eq('/var/lib/data.img')
    end
  end

  it 'produces stable socket paths for a machine and hash base' do
    with_tmpdir do |dir|
      machine = build_machine(dir:, name: 'alpha', hash_base: 'suite')
      socket_path = machine.send(:socket_path, 'console.sock')

      expect(socket_path).to eq(File.join(dir, 'sock', "#{Digest::SHA256.hexdigest('suitealpha')[0..7]}-console.sock"))
    end
  end

  it 'renders qemu boot options for direct boot' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)

      expect(machine.send(:qemu_boot_options, ['debug'])).to eq(
        [
          '-kernel', '/boot/kernel',
          '-initrd', '/boot/initrd',
          '-append', 'console=ttyS0 init=/run/current-system/init panic=1 debug'
        ]
      )
    end
  end

  it 'renders qemu boot options for firmware boot' do
    with_tmpdir do |dir|
      config = build_machine_config(
        {
          'bootMode' => 'firmware',
          'bootOrder' => 'dc',
          'kernel' => nil,
          'initrd' => nil,
          'toplevel' => nil,
          'squashfs' => nil
        }
      )
      machine = build_machine(dir:, config:)

      expect(machine.send(:qemu_boot_options, [])).to eq(['-boot', 'order=dc'])
    end
  end

  it 'renders qemu disk options for configured disks' do
    with_tmpdir do |dir|
      config = build_machine_config(
        'disks' => [
          { 'device' => '{machine}-data.img', 'type' => 'file', 'size' => '1G' },
          { 'device' => '/var/lib/extra.img', 'type' => 'file', 'size' => '2G' }
        ]
      )
      machine = build_machine(dir:, name: 'alpha', config:)

      expect(machine.send(:qemu_disk_options)).to eq(
        [
          '-drive', "id=disk0,file=#{File.join(dir, 'tmp', 'alpha-data.img')},if=none,format=raw",
          '-device', 'ide-hd,drive=disk0,bus=ahci.0',
          '-drive', 'id=disk1,file=/var/lib/extra.img,if=none,format=raw',
          '-device', 'ide-hd,drive=disk1,bus=ahci.1'
        ]
      )
    end
  end

  it 'renders virtiofs qemu options when shared filesystems exist' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)

      options = machine.send(:qemu_virtiofs_options)

      expect(options).to include('-object', 'memory-backend-file,id=m0,size=512M,mem-path=/dev/shm,share=on')
      expect(options).to include('-numa', 'node,memdev=m0')
      expect(options.grep(/tag=vmSharedDir/).first).not_to be_nil
      expect(options.grep(/tag=extra/).first).not_to be_nil
    end
  end

  it 'destroys only file-backed disks marked for creation' do
    with_tmpdir do |dir|
      config = build_machine_config(
        'disks' => [
          { 'device' => '{machine}-keep.img', 'type' => 'file', 'size' => '1G', 'create' => false },
          { 'device' => '{machine}-remove.img', 'type' => 'file', 'size' => '1G', 'create' => true },
          { 'device' => '/dev/loop0', 'type' => 'blockdev', 'size' => '1G', 'create' => true }
        ]
      )
      machine = build_machine(dir:, name: 'alpha', config:)
      removable = File.join(dir, 'tmp', 'alpha-remove.img')
      kept = File.join(dir, 'tmp', 'alpha-keep.img')

      File.write(removable, 'x')
      File.write(kept, 'y')

      expect(machine.destroy_disks).to eq(machine)
      expect(File.exist?(removable)).to be(false)
      expect(File.exist?(kept)).to be(true)
    end
  end

  it 'cleans up shell and virtiofs sockets' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      shell_socket = machine.send(:shell_socket_path)
      virtio_sockets = machine.send(:shared_filesystems).keys.map do |fs_name|
        machine.send(:virtiofs_socket_path, fs_name)
      end

      FileUtils.touch(shell_socket)
      virtio_sockets.each { |path| FileUtils.touch(path) }

      expect(machine.cleanup).to eq(machine)
      expect(File.exist?(shell_socket)).to be(false)
      expect(virtio_sockets.any? { |path| File.exist?(path) }).to be(false)
    end
  end

  it 'delegates pull_file to the shared dir' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      shared_dir = instance_double(OsVm::SharedDir, pull_file: '/tmp/copied.txt')
      machine.instance_variable_set(:@shared_dir, shared_dir)

      expect(machine.pull_file('/etc/target.txt', preserve: true)).to eq('/tmp/copied.txt')
      expect(shared_dir).to have_received(:pull_file).with('/etc/target.txt', preserve: true)
    end
  end

  it 'raises when stop times out waiting for the qemu reaper' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      machine.instance_variable_set(:@qemu_reaper, instance_double(Thread, join: nil))
      allow(machine).to receive(:execute).and_return([0, ''])

      expect do
        machine.stop(timeout: 0)
      end.to raise_error(OsVm::UnrecoverableTimeoutError, /Timeout while stopping machine/)
    end
  end

  it 'waits until commands succeed' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      allow(machine).to receive(:execute).and_return([1, 'not yet'], [0, 'ready'])
      allow(machine).to receive(:sleep)

      expect(machine.wait_until_succeeds('true')).to eq([0, 'ready'])
    end
  end

  it 'times out while waiting for commands to succeed' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      allow(machine).to receive(:execute).and_return([1, 'not yet'])

      expect do
        machine.wait_until_succeeds('true', timeout: 0)
      end.to raise_error(OsVm::TimeoutError, /Timeout occurred while running command 'true'/)
    end
  end

  it 'waits until commands fail' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      allow(machine).to receive(:execute).and_return([0, 'still up'], [1, 'failed'])
      allow(machine).to receive(:sleep)

      expect(machine.wait_until_fails('false')).to eq([1, 'failed'])
    end
  end

  it 'times out while waiting for commands to fail' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      allow(machine).to receive(:execute).and_return([0, 'still up'])

      expect do
        machine.wait_until_fails('false', timeout: 0)
      end.to raise_error(OsVm::TimeoutError, /Timeout occurred while running command 'false'/)
    end
  end

  it 'waits for services using the subclass service check command' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      allow(machine).to receive(:wait_until_succeeds).and_return([0, ''])

      expect(machine.wait_for_service('sshd')).to eq(machine)
      expect(machine).to have_received(:wait_until_succeeds).with('sv check sshd')
    end
  end

  it 'waits for console text successfully' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      machine.instance_variable_set(:@console_output, "system booted\nready\n")
      machine.instance_variable_set(:@running, true)

      expect(machine.wait_for_console_text(/ready/, timeout: 0)).to eq(machine)
    end
  end

  it 'returns captured console output' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      machine.instance_variable_set(:@console_output, "system booted\nready\n")

      expect(machine.console_output).to eq("system booted\nready\n")
    end
  end

  it 'times out waiting for console text' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      machine.instance_variable_set(:@console_output, '')
      machine.instance_variable_set(:@running, true)

      expect do
        machine.wait_for_console_text(/ready/, timeout: 0)
      end.to raise_error(OsVm::TimeoutError, %r{Timeout occurred while waiting for /ready/})
    end
  end

  it 'fails waiting for console text when the machine is not running' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      machine.instance_variable_set(:@console_output, '')
      machine.instance_variable_set(:@running, false)

      expect do
        machine.wait_for_console_text(/ready/, timeout: 1)
      end.to raise_error(OsVm::Error, 'Machine is not running')
    end
  end

  it 'resets the shell and raises when shell output hits eof' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      shell = instance_double(IO, wait_readable: true, closed?: false, close: nil)
      machine.instance_variable_set(:@shell, shell)
      machine.instance_variable_set(:@shell_up, true)
      allow(machine).to receive(:read_nonblock).and_raise(EOFError)

      expect do
        machine.send(:read_shell_output, timeout: 1, command: 'echo test')
      end.to raise_error(OsVm::MachineShellClosed)

      expect(machine.instance_variable_get(:@shell)).to be_nil
      expect(machine.instance_variable_get(:@shell_up)).to be(false)
    end
  end

  it 'formats inspect output with the machine name' do
    with_tmpdir do |dir|
      machine = build_machine(dir:, name: 'alpha')

      expect(machine.inspect).to match(/name=alpha>/)
    end
  end
end
