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

  it 'treats console EOF as a normal shutdown' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      console_read, console_write = IO.pipe
      machine.instance_variable_set(:@qemu_read, console_read)

      machine.send(:run_console_thread)
      console_write.write('console output')
      console_write.close

      thread = machine.send(:console_thread)
      expect(thread.join(5)).to be(thread)
      expect(thread.value).to be_nil
      expect(File.read(machine.send(:console_log_path))).to eq('console output')
    ensure
      console_write&.close unless console_write&.closed?
      console_read&.close unless console_read&.closed?
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

  it 'keeps the exact reaper when an immediate exit clears published state' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      reaper = instance_double(OsVm::Machine::QemuReaper, join: true)
      machine.instance_variable_set(:@qemu_reaper, reaper)
      machine.instance_variable_set(:@running, true)
      allow(machine).to receive(:execute) do
        machine.send(:mark_runtime_stopped)
        [0, '']
      end

      expect(machine.stop(timeout: 3)).to eq(machine)

      expect(reaper).to have_received(:join).with(3).once
      expect(machine.send(:qemu_reaper)).to be_nil
      expect(machine).not_to be_running
    end
  end

  it 'signals the snapshotted reaper when running state clears concurrently' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      reaper = instance_double(OsVm::Machine::QemuReaper, signal: true, join: true)
      machine.instance_variable_set(:@qemu_reaper, reaper)
      machine.instance_variable_set(:@running, true)
      allow(machine).to receive(:running?) do
        machine.send(:mark_runtime_stopped)
        true
      end

      expect(machine.kill(signal: 'KILL')).to eq(machine)

      expect(reaper).to have_received(:signal).with('KILL').once
      expect(reaper).to have_received(:join).once
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

  it 'keeps a sub-five-second online budget through the real shell protocol' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      shell = machine.send(:current_shell)
      writes = []
      wait_timeouts = []
      io = instance_double(IO, closed?: false, close: nil)
      allow(io).to receive(:write) { |data| writes << data }
      allow(io).to receive(:wait_readable) do |timeout|
        wait_timeouts << timeout
        true
      end
      allow(io).to receive(:read_nonblock).and_return(
        "#{Base64.strict_encode64('online')}\n",
        "0\n"
      )
      machine.instance_variable_set(:@running, true)
      shell.instance_variable_set(:@up, true)
      shell.instance_variable_set(:@io, io)

      expect(machine.wait_until_online(timeout: 0.5)).to eq(machine)

      guest_timeout = writes.first.match(/timeout ([0-9.]+)/)[1].to_f
      expect(guest_timeout).to be_between(0, 0.5).exclusive
      expect(wait_timeouts).not_to be_empty
      expect(wait_timeouts).to all(be_between(0, 0.5).exclusive)
    end
  end

  it 'does not add output-read allowances beyond the online deadline' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      shell = machine.send(:current_shell)
      wait_timeouts = []
      io = instance_double(IO, closed?: false, close: nil, write: nil)
      allow(io).to receive(:wait_readable) do |timeout|
        wait_timeouts << timeout
        sleep(timeout)
        false
      end
      machine.instance_variable_set(:@running, true)
      shell.instance_variable_set(:@up, true)
      shell.instance_variable_set(:@io, io)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect do
        machine.wait_until_online(timeout: 0.05)
      end.to raise_error(OsVm::TimeoutError, /waiting for network to become online/)

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      expect(elapsed).to be < 0.5
      expect(wait_timeouts).not_to be_empty
      expect(wait_timeouts).to all(be_between(0, 0.05).exclusive)
    end
  end

  it 'caps the five-second restart delay at the startup deadline' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      machine.instance_variable_set(:@stopped_at, Time.now)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.05
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect do
        machine.start(deadline:, timeout_message: 'startup deadline expired')
      end.to raise_error(OsVm::TimeoutError, 'startup deadline expired')

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      expect(elapsed).to be < 0.5
      expect(machine).not_to be_running
    end
  end

  it 'rolls back prepared listeners and virtiofs after startup expires' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      shell = machine.send(:current_shell)
      allow(machine).to receive(:start_virtiofs) do
        machine.send(:virtiofsd_pids) << 12_345
      end
      allow(machine).to receive(:stop_virtiofs) do
        machine.send(:virtiofsd_pids).clear
      end
      allow(machine).to receive(:sleep_with_deadline).and_raise(
        OsVm::TimeoutError,
        'startup deadline expired'
      )

      expect do
        machine.start(
          deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10,
          timeout_message: 'startup deadline expired'
        )
      end.to raise_error(OsVm::TimeoutError, 'startup deadline expired')

      expect(machine).not_to be_running
      expect(machine.send(:virtiofsd_pids)).to be_empty
      expect(shell.send(:server)).to be_nil
      expect(File.exist?(shell.socket_path)).to be(false)
      expect(machine).to have_received(:stop_virtiofs).once
    end
  end

  it 'reaps an earlier virtiofs child when a later spawn fails' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      shell = machine.send(:current_shell)
      spawn_calls = 0
      allow(Process).to receive(:spawn) do
        spawn_calls += 1
        raise OsVm::TimeoutError, 'startup deadline expired' if spawn_calls == 2

        12_345
      end
      allow(Process).to receive(:kill).with('TERM', 12_345)
      allow(Process).to receive(:wait).with(12_345)

      expect do
        machine.start(
          deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10,
          timeout_message: 'startup deadline expired'
        )
      end.to raise_error(OsVm::TimeoutError, 'startup deadline expired')

      expect(spawn_calls).to eq(2)
      expect(Process).to have_received(:kill).with('TERM', 12_345).once
      expect(Process).to have_received(:wait).with(12_345).once
      expect(machine.send(:virtiofsd_pids)).to be_empty
      expect(machine).not_to be_running
      expect(shell.send(:server)).to be_nil
      expect(File.exist?(shell.socket_path)).to be(false)
    end
  end

  it 'takes back QEMU ownership when startup expires around reaper handoff' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      shell = machine.send(:current_shell)
      allow(machine).to receive(:start_virtiofs)
      allow(machine).to receive(:stop_virtiofs)
      allow(machine).to receive(:sleep_with_deadline)
      allow(Process).to receive(:spawn).and_return(43_210)
      status = instance_double(Process::Status, exitstatus: 0)
      allow(Process).to receive(:waitpid2).with(43_210, Process::WNOHANG).and_return(nil)
      allow(Process).to receive(:waitpid2).with(43_210).and_return([43_210, status])
      allow(Process).to receive(:kill).with('KILL', 43_210)
      allow(machine).to receive(:run_qemu_reaper).with(43_210).and_raise(
        OsVm::TimeoutError,
        'startup deadline expired'
      )

      expect do
        machine.start(
          deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10,
          timeout_message: 'startup deadline expired'
        )
      end.to raise_error(OsVm::TimeoutError, 'startup deadline expired')

      expect(Process).to have_received(:kill).with('KILL', 43_210).once
      expect(Process).to have_received(:waitpid2).with(43_210, Process::WNOHANG).once
      expect(Process).to have_received(:waitpid2).with(43_210).once
      expect(machine).not_to be_running
      expect(machine.send(:qemu_pid)).to be_nil
      expect(machine.send(:qemu_read)).to be_nil
      expect(shell.send(:server)).to be_nil
    end
  end

  it 'activates a published paused reaper when pre-start console setup fails' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      failure = RuntimeError.new('console setup failed')
      status = instance_double(Process::Status, exitstatus: 0)
      wait_calls = 0
      allow(machine).to receive(:start_virtiofs)
      allow(machine).to receive(:stop_virtiofs)
      allow(machine).to receive(:sleep_with_deadline)
      allow(machine).to receive(:run_console_thread).and_raise(failure)
      allow(Process).to receive(:spawn).and_return(43_210)
      allow(Process).to receive(:waitpid2).with(43_210, Process::WNOHANG) do
        wait_calls += 1
        wait_calls == 1 ? nil : [43_210, status]
      end
      allow(Process).to receive(:kill).with('KILL', 43_210)

      expect do
        Timeout.timeout(5) do
          machine.start(
            deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10,
            timeout_message: 'startup deadline expired'
          )
        end
      end.to raise_error(failure)

      expect(Process).to have_received(:kill).with('KILL', 43_210).once
      expect(wait_calls).to eq(2)
      expect(machine.send(:qemu_reaper)).to be_nil
      expect(machine).not_to be_running
    end
  end

  it 'defers a second timeout until startup rollback reclaims every resource' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      shell = machine.send(:current_shell)
      rollback_entered = Queue.new
      release_rollback = Queue.new
      result = Queue.new
      first_error = OsVm::TimeoutError.new('first startup timeout')
      second_error = OsVm::TimeoutError.new('second startup timeout')

      allow(machine).to receive(:start_virtiofs) do
        machine.send(:virtiofsd_pids) << 12_345
      end
      allow(machine).to receive(:stop_virtiofs) do
        machine.send(:virtiofsd_pids).clear
      end
      allow(machine).to receive(:sleep_with_deadline)
      allow(machine).to receive(:wait_for_boot).and_raise(first_error)
      allow(machine).to receive(:run_qemu_reaper).with(43_210).and_return(nil)
      allow(Process).to receive(:spawn).and_return(43_210)
      status = instance_double(Process::Status, exitstatus: 0)
      allow(Process).to receive(:waitpid2).with(43_210, Process::WNOHANG).and_return(nil)
      allow(Process).to receive(:waitpid2).with(43_210).and_return([43_210, status])
      allow(Process).to receive(:kill).with('KILL', 43_210) do
        rollback_entered << true
        Timeout.timeout(5) { release_rollback.pop }
      end

      start_thread = Thread.new do
        Thread.current.report_on_exception = false
        machine.start(
          wait_for_boot: true,
          deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10,
          timeout_message: 'startup deadline expired'
        )
      rescue StandardError => e
        result << e
      end

      Timeout.timeout(5) { rollback_entered.pop }
      injector = Thread.new { start_thread.raise(second_error) }
      Timeout.timeout(5) do
        sleep(0.01) until start_thread.pending_interrupt?(OsVm::TimeoutError)
      end
      expect { result.pop(true) }.to raise_error(ThreadError)

      release_rollback << true
      expect(injector.join(5)).to be(injector)
      expect(start_thread.join(5)).to be(start_thread)
      expect(Timeout.timeout(5) { result.pop }).to be(second_error)

      expect(Process).to have_received(:kill).with('KILL', 43_210).once
      expect(Process).to have_received(:waitpid2).with(43_210, Process::WNOHANG).once
      expect(Process).to have_received(:waitpid2).with(43_210).once
      expect(machine.send(:virtiofsd_pids)).to be_empty
      expect(machine.send(:qemu_pid)).to be_nil
      expect(machine.send(:qemu_read)).to be_nil
      expect(machine.send(:console_thread)).to be_nil
      expect(machine).not_to be_running
      expect(shell.send(:server)).to be_nil
      expect(File.exist?(shell.socket_path)).to be(false)
    ensure
      release_rollback&.push(true) if start_thread&.alive?
      injector&.join(5)
      start_thread&.join(5)
    end
  end

  it 'never kills a reaped immediate-exit PID when startup times out later' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      observed_running = Queue.new
      child_reaped = Queue.new
      allow(machine).to receive(:start_virtiofs)
      allow(machine).to receive(:stop_virtiofs).and_call_original
      allow(machine).to receive(:cleanup).and_call_original
      allow(machine).to receive(:sleep_with_deadline)
      allow(machine).to receive(:wait_for_boot) do
        Timeout.timeout(5) { child_reaped.pop }
        raise OsVm::TimeoutError, 'startup deadline expired'
      end
      allow(Process).to receive(:spawn).and_return(43_210)
      status = instance_double(Process::Status, exitstatus: 0)
      allow(Process).to receive(:waitpid2).with(43_210, Process::WNOHANG) do
        observed_running << machine.running?
        child_reaped << true
        [43_210, status]
      end
      allow(Process).to receive(:kill)

      expect do
        machine.start(
          wait_for_boot: true,
          deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10,
          timeout_message: 'startup deadline expired'
        )
      end.to raise_error(OsVm::TimeoutError, 'startup deadline expired')

      expect(Timeout.timeout(5) { observed_running.pop }).to be(true)
      expect(Process).not_to have_received(:kill).with('KILL', 43_210)
      expect(machine).not_to be_running
      expect(machine.send(:qemu_pid)).to be_nil
      expect(machine.send(:qemu_read)).to be_nil
      expect(machine).to have_received(:stop_virtiofs).twice
      expect(machine).to have_received(:cleanup).twice
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
