# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

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

  it 'renders qemu boot media for configured ISO images' do
    with_tmpdir do |dir|
      machine = build_machine(dir:, config: build_machine_config('iso' => '/images/install.iso'))
      no_media_machine = build_machine(dir:)

      expect(machine.send(:qemu_boot_media_options)).to eq(['-cdrom', '/images/install.iso'])
      expect(no_media_machine.send(:qemu_boot_media_options)).to eq([])
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
      machine = build_machine(
        dir:,
        config: build_machine_config('testShells' => 2)
      )
      shell_sockets = [
        machine.send(:shell_socket_path, 0),
        machine.send(:shell_socket_path, 1)
      ]
      virtio_sockets = machine.send(:shared_filesystems).keys.map do |fs_name|
        machine.send(:virtiofs_socket_path, fs_name)
      end

      shell_sockets.each { |path| FileUtils.touch(path) }
      virtio_sockets.each { |path| FileUtils.touch(path) }

      expect(machine.cleanup).to eq(machine)
      expect(shell_sockets.any? { |path| File.exist?(path) }).to be(false)
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

  it 'waits for cleanup when qemu was reaped before kill' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      reaper = instance_double(Thread)
      machine.instance_variable_set(:@running, true)
      machine.instance_variable_set(:@qemu_pid, nil)
      machine.instance_variable_set(:@qemu_reaper, reaper)
      allow(reaper).to receive(:join)
      allow(Process).to receive(:kill)

      expect(machine.kill).to eq(machine)
      expect(Process).not_to have_received(:kill)
      expect(reaper).to have_received(:join)
    end
  end

  it 'tolerates qemu exiting before a kill signal is delivered' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      reaper = instance_double(Thread)
      machine.instance_variable_set(:@running, true)
      machine.instance_variable_set(:@qemu_pid, 123)
      machine.instance_variable_set(:@qemu_reaper, reaper)
      allow(reaper).to receive(:join)
      allow(machine).to receive(:warn)
      allow(Process).to receive(:kill).with('KILL', 123).and_raise(Errno::ESRCH)

      expect(machine.kill(signal: 'KILL')).to eq(machine)
      expect(machine).to have_received(:warn).with(/Unable to kill machine test using SIGKILL/)
      expect(reaper).to have_received(:join)
    end
  end

  it 'escalates to sigkill only while the same qemu process is active' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      reaper = instance_double(Thread)
      machine.instance_variable_set(:@running, true)
      machine.instance_variable_set(:@qemu_pid, 123)
      machine.instance_variable_set(:@qemu_reaper, reaper)
      allow(reaper).to receive(:join)
      allow(machine).to receive(:wait_for_qemu_exit).with(123, 60).and_return(false)
      allow(Process).to receive(:kill)

      expect(machine.kill).to eq(machine)
      expect(Process).to have_received(:kill).with('TERM', 123).ordered
      expect(Process).to have_received(:kill).with('KILL', 123).ordered
      expect(reaper).to have_received(:join)
    end
  end

  it 'does not signal a pid after the reaper has reaped it' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      status = instance_double(Process::Status, exitstatus: 0, signaled?: false)
      wait_entered = Queue.new
      release_wait = Queue.new
      reaper = nil
      killer = nil

      machine.instance_variable_set(:@running, true)
      machine.instance_variable_set(:@qemu_pid, 123)
      allow(Process).to receive(:wait2).with(123, Process::WNOHANG) do
        wait_entered << true
        release_wait.pop
        [123, status]
      end
      allow(Process).to receive(:kill)

      machine.send(:qemu_mutex).synchronize do
        reaper = machine.send(:run_qemu_reaper, 123)
        machine.instance_variable_set(:@qemu_reaper, reaper)
      end

      wait_entered.pop
      killer = Thread.new { machine.send(:signal_qemu, 'KILL', 123) }
      Timeout.timeout(1) { Thread.pass until killer.status == 'sleep' }
      release_wait << true
      reaper.value
      killer.value

      expect(Process).not_to have_received(:kill)
    ensure
      release_wait << true if reaper&.alive?
      reaper&.join
      killer&.join
    end
  end

  it 'waits until commands succeed' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      shell = machine.send(:current_shell)
      allow(shell).to receive(:execute).and_return([1, 'not yet'], [0, 'ready'])
      allow(shell).to receive(:sleep)

      expect(machine.wait_until_succeeds('true')).to eq([0, 'ready'])
    end
  end

  it 'times out while waiting for commands to succeed' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      shell = machine.send(:current_shell)
      allow(shell).to receive(:execute).and_return([1, 'not yet'])

      expect do
        machine.wait_until_succeeds('true', timeout: 0)
      end.to raise_error(OsVm::TimeoutError, /Timeout occurred while running command 'true'/)
    end
  end

  it 'waits until commands fail' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      shell = machine.send(:current_shell)
      allow(shell).to receive(:execute).and_return([0, 'still up'], [1, 'failed'])
      allow(shell).to receive(:sleep)

      expect(machine.wait_until_fails('false')).to eq([1, 'failed'])
    end
  end

  it 'times out while waiting for commands to fail' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      shell = machine.send(:current_shell)
      allow(shell).to receive(:execute).and_return([0, 'still up'])

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

  it 'detects fatal kernel output split across console reads' do
    with_tmpdir do |dir|
      machine = build_machine(dir:, name: 'services')

      machine.send(:append_console_output, '[    7.067] BUG: unable to handle page')
      expect(machine.kernel_failed?).to be(false)

      machine.send(:append_console_output, " fault for address: ffffffffc0ef7000\r\n")

      expect(machine.kernel_failed?).to be(true)
      expect { machine.raise_if_kernel_failed! }
        .to raise_error(OsVm::KernelFailure) do |error|
          expect(error.machine_name).to eq('services')
          expect(error.console_line).to include('BUG: unable to handle page fault')
          expect(error.console_log_path).to end_with('services-console.log')
        end
    end
  end

  it 'flushes an empty console scan buffer when the console closes' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      machine.send(:append_console_output, "ordinary output\n")

      expect { machine.send(:append_console_output, '', flush: true) }
        .not_to raise_error
      expect(machine.kernel_failed?).to be(false)
    end
  end

  it 'detects fatal kernel signatures for both machine spins' do
    with_tmpdir do |dir|
      machines = [
        build_vpsadminos_machine(dir:, name: 'vpsadminos'),
        build_nixos_machine(dir:, name: 'nixos')
      ]

      machines.each do |machine|
        machine.send(:append_console_output, "[    1.000] Oops: 0003 [#1] SMP\n")
        expect { machine.raise_if_kernel_failed! }.to raise_error(OsVm::KernelFailure)
      end
    end
  end

  it 'recognizes all fatal kernel signature classes' do
    signatures = [
      'BUG: unable to handle page fault for address: deadbeef',
      'BUG: kernel NULL pointer dereference, address: 0',
      'kernel BUG at arch/x86/kernel/alternative.c:2531!',
      'Oops: 0003 [#1] SMP',
      'general protection fault, probably for non-canonical address',
      'Kernel panic - not syncing: fatal exception'
    ]

    with_tmpdir do |dir|
      signatures.each_with_index do |signature, i|
        machine = build_machine(dir:, name: "machine#{i}")
        machine.send(:append_console_output, "[    1.000] #{signature}\n")

        expect { machine.raise_if_kernel_failed! }.to raise_error(OsVm::KernelFailure, /#{Regexp.escape(signature)}/)
      end
    end
  end

  it 'does not treat warnings and sanitizers as fatal kernel output' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      machine.send(
        :append_console_output,
        "[    1.000] WARNING: suspicious state\nKASAN: use-after-free\nUBSAN: array index out of bounds\n"
      )

      expect(machine.kernel_failed?).to be(false)
      expect(machine.raise_if_kernel_failed!).to eq(machine)
    end
  end

  it 'retains the first unexpected kernel failure' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      machine.send(:append_console_output, "[    1.000] Oops: first failure\n")
      machine.send(:append_console_output, "[    2.000] Kernel panic - not syncing: second failure\n")

      expect { machine.raise_if_kernel_failed! }
        .to raise_error(OsVm::KernelFailure, /first failure/)
    end
  end

  it 'allows only matching kernel failures within a scoped block' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)

      machine.allow_kernel_failure(/sysrq triggered crash/) do
        machine.send(
          :append_console_output,
          "[    1.000] Kernel panic - not syncing: sysrq triggered crash\n"
        )
      end

      expect(machine.kernel_failed?).to be(false)

      machine.allow_kernel_failure(/sysrq triggered crash/) do
        machine.send(:append_console_output, "[    2.000] Oops: unrelated failure\n")
      end

      expect { machine.raise_if_kernel_failed! }
        .to raise_error(OsVm::KernelFailure, /unrelated failure/)
    end
  end

  it 'ends a kernel failure allowance when its block raises' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)

      expect do
        machine.allow_kernel_failure(/expected panic/) { raise 'test failure' }
      end.to raise_error('test failure')

      machine.send(
        :append_console_output,
        "[    1.000] Kernel panic - not syncing: expected panic\n"
      )

      expect { machine.raise_if_kernel_failed! }.to raise_error(OsVm::KernelFailure)
    end
  end

  it 'interrupts a join when the console reports a kernel failure' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      reaper = instance_double(Thread)
      waits = []
      allow(reaper).to receive(:join) do |timeout|
        waits << timeout
        machine.send(:append_console_output, "[    1.000] Oops: join failure\n")
        nil
      end
      allow(machine).to receive(:qemu_state).and_return([123, reaper, true])

      expect { machine.join(timeout: 10) }
        .to raise_error(OsVm::KernelFailure, /join failure/)
      expect(waits.length).to eq(1)
      expect(waits.first).to be <= 1
    end
  end

  it 'interrupts the post-poweroff wait on a kernel failure' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      reaper = instance_spy(Thread, join: nil)
      allow(machine).to receive(:execute) do
        machine.send(:append_console_output, "[    1.000] Oops: stop failure\n")
        [0, '']
      end
      allow(machine).to receive(:qemu_state).and_return([123, reaper, true])

      expect { machine.stop(timeout: 10) }
        .to raise_error(OsVm::KernelFailure, /stop failure/)
      expect(reaper).not_to have_received(:join)
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

  it 'renders qemu options for multiple test shells' do
    with_tmpdir do |dir|
      machine = build_machine(
        dir:,
        config: build_machine_config('testShells' => 2)
      )

      expect(machine.send(:qemu_shell_options)).to eq(
        [
          '-device', 'virtio-serial',
          '-chardev', "socket,id=shell,path=#{machine.send(:shell_socket_path, 0)}",
          '-device', 'virtconsole,chardev=shell',
          '-chardev', "socket,id=shell1,path=#{machine.send(:shell_socket_path, 1)}",
          '-device', 'virtconsole,chardev=shell1'
        ]
      )
    end
  end

  it 'exposes named shells after worker shells' do
    with_tmpdir do |dir|
      machine = build_machine(
        dir:,
        config: build_machine_config('testShells' => 4, 'shells' => %w[first second])
      )

      expect(machine.shells.keys).to eq(%w[first second])
      expect(machine.shells['first'].index).to eq(2)
      expect(machine.shells[:second].index).to eq(3)
      expect(machine.shells['first'].name).to eq('first')
      expect(machine.shells.include?(:second)).to be(true)

      expect do
        machine.shells['missing']
      end.to raise_error(KeyError, /unknown shell "missing" for machine test/)
    end
  end

  it 'forwards command helpers to named shells' do
    with_tmpdir do |dir|
      machine = build_machine(
        dir:,
        config: build_machine_config('testShells' => 2, 'shells' => ['aux'])
      )
      aux_shell = machine.shells['aux']
      allow(aux_shell).to receive(:execute).with('echo aux', timeout: 10).and_return([0, "aux\n"])
      allow(aux_shell).to receive(:succeeds).with('true', timeout: 7).and_return([0, ''])
      allow(aux_shell).to receive(:succeeds_with_retries)
        .with('flaky', attempts: 3, retry_delay: 2, timeout: 11)
        .and_return([0, 'ready'])
      allow(aux_shell).to receive(:fails).with('false', timeout: 8).and_return([1, ''])
      allow(aux_shell).to receive(:fails_with_retries)
        .with('eventually-down', attempts: 4, retry_delay: 3, timeout: 12)
        .and_return([1, 'stopped'])
      allow(aux_shell).to receive(:all_succeed).with('a', 'b').and_return([[0, 'a'], [0, 'b']])
      allow(aux_shell).to receive(:all_fail).with('a', 'b').and_return([[1, 'a'], [1, 'b']])
      allow(aux_shell).to receive(:wait_until_succeeds).with('ready', timeout: 9).and_return([0, 'ready'])
      allow(aux_shell).to receive(:wait_until_fails).with('down', timeout: 6).and_return([1, 'down'])

      expect(machine.execute('echo aux', shell: 'aux')).to eq([0, "aux\n"])
      expect(machine.succeeds('true', timeout: 7, shell: :aux)).to eq([0, ''])
      expect(
        machine.succeeds_with_retries(
          'flaky', attempts: 3, retry_delay: 2, timeout: 11, shell: :aux
        )
      ).to eq([0, 'ready'])
      expect(machine.fails('false', timeout: 8, shell: 'aux')).to eq([1, ''])
      expect(
        machine.fails_with_retries(
          'eventually-down', attempts: 4, retry_delay: 3, timeout: 12, shell: :aux
        )
      ).to eq([1, 'stopped'])
      expect(machine.all_succeed('a', 'b', shell: 'aux')).to eq([[0, 'a'], [0, 'b']])
      expect(machine.all_fail('a', 'b', shell: 'aux')).to eq([[1, 'a'], [1, 'b']])
      expect(machine.wait_until_succeeds('ready', timeout: 9, shell: 'aux')).to eq([0, 'ready'])
      expect(machine.wait_until_fails('down', timeout: 6, shell: 'aux')).to eq([1, 'down'])
    end
  end

  it 'formats inspect output with the machine name' do
    with_tmpdir do |dir|
      machine = build_machine(dir:, name: 'alpha')

      expect(machine.inspect).to match(/name=alpha>/)
    end
  end
end
