# frozen_string_literal: true

require 'spec_helper'
require 'io/wait'

RSpec.describe OsVm::Shell do
  def build_shell(
    dir:,
    machine: instance_double(OsVm::Machine, name: 'test', running?: true, raise_if_kernel_failed!: nil)
  )
    described_class.new(
      machine,
      0,
      File.join(dir, 'shell.sock'),
      File.join(dir, 'shell.log'),
      default_timeout: 10
    )
  end

  def with_command_shell
    with_tmpdir do |dir|
      shell = build_shell(dir:)

      IO.popen(%w[bash --noprofile --norc], 'r+') do |io|
        io.sync = true
        shell.instance_variable_set(:@io, io)
        shell.instance_variable_set(:@up, true)
        yield shell, io
      end
    ensure
      shell&.finalize
    end
  end

  it 'does not attribute a late response from a timed-out command to the next command' do
    with_command_shell do |shell, io|
      io.write("printf '#{Base64.strict_encode64('late reply')}\\n0\\n'\n")

      expect(shell.execute('printf current')).to eq([0, 'current'])
      expect(shell.execute('printf next; exit 37')).to eq([37, 'next'])
    end
  end

  it 'preserves binary output and empty output with the matching exit status' do
    with_command_shell do |shell, _io|
      expect(shell.execute("printf 'line\\n\\000\\377tail'; exit 17")).to eq(
        [17, "line\n\x00\xfftail".b]
      )
      expect(shell.execute('true')).to eq([0, ''])
    end
  end

  it 'reads a framed response larger than an IO read buffer' do
    with_command_shell do |shell, _io|
      payload = '0123456789' * 2000

      expect(shell.execute("printf '#{payload}'")).to eq([0, payload])
    end
  end

  it 'preserves a large reply, its exit status, and the following reply' do
    with_command_shell do |shell, _io|
      expect(shell.execute("head -c 1048576 /dev/zero | tr '\\0' x; exit 37")).to eq([37, 'x' * 1_048_576])
      expect(shell.execute('printf after; exit 11')).to eq([11, 'after'])
    end
  end

  it 'ignores stale framed records without renewing the response deadline' do
    with_tmpdir do |dir|
      shell = build_shell(dir:)
      started_at = Time.at(100)
      allow(Time).to receive(:now).and_return(started_at, started_at + 1, started_at + 3)
      allow(shell).to receive(:read_output).and_return(
        "bGF0ZQ==:old-marker:0\n",
        "c3RhbGU=:other-marker:0\nY3VycmVudA==:current-marker:27\n"
      )

      expect(shell.send(:read_command_result, 'current-marker', timeout: 5, command: 'test')).to eq(
        [27, 'current']
      )
      expect(shell).to have_received(:read_output).with(timeout: 4, command: 'test')
      expect(shell).to have_received(:read_output).with(timeout: 2, command: 'test')
    ensure
      shell&.finalize
    end
  end

  it 'keeps ordinary command timeouts and can execute the following command' do
    with_command_shell do |shell, _io|
      expect do
        shell.execute('printf partial; sleep 10', timeout: 5)
      end.to raise_error(OsVm::TimeoutError, /output: "partial"/)

      expect(shell.execute('printf after')).to eq([0, 'after'])
    end
  end

  it 'builds qemu options from its index and socket path' do
    with_tmpdir do |dir|
      shell = described_class.new(
        instance_double(OsVm::Machine),
        2,
        File.join(dir, 'shell2.sock'),
        File.join(dir, 'shell2.log'),
        default_timeout: 10
      )

      expect(shell.chardev_id).to eq('shell2')
      expect(shell.qemu_options).to eq(
        [
          '-chardev', "socket,id=shell2,path=#{File.join(dir, 'shell2.sock')}",
          '-device', 'virtconsole,chardev=shell2'
        ]
      )
    end
  end

  it 'resets and raises when shell output hits eof' do
    with_tmpdir do |dir|
      shell = build_shell(dir:)
      io = instance_double(IO, wait_readable: true, closed?: false, close: nil)
      shell.instance_variable_set(:@io, io)
      shell.instance_variable_set(:@up, true)
      allow(shell).to receive(:read_nonblock).and_raise(EOFError)

      expect do
        shell.send(:read_output, timeout: 1, command: 'echo test')
      end.to raise_error(OsVm::MachineShellClosed)

      expect(shell.instance_variable_get(:@io)).to be_nil
      expect(shell).not_to be_up
    end
  end

  it 'does not restart a stopped machine after a detected kernel failure' do
    with_tmpdir do |dir|
      failure = OsVm::KernelFailure.new(
        machine_name: 'test',
        console_line: 'Oops: test failure',
        console_log_path: File.join(dir, 'console.log')
      )
      machine = instance_double(OsVm::Machine, running?: false, start: nil, name: 'test')
      allow(machine).to receive(:raise_if_kernel_failed!).and_raise(failure)
      shell = build_shell(dir:, machine:)

      expect { shell.execute('true') }.to raise_error(failure)
      expect(machine).not_to have_received(:start)
    end
  end

  it 'checks successful and failed commands' do
    with_tmpdir do |dir|
      shell = build_shell(dir:)

      allow(shell).to receive(:execute).with('true', timeout: 10).and_return([0, "ok\n"])
      allow(shell).to receive(:execute).with('false', timeout: 10).and_return([1, "fail\n"])

      expect(shell.succeeds('true')).to eq([0, "ok\n"])
      expect(shell.fails('false')).to eq([1, "fail\n"])
    end
  end

  it 'raises when success expectations are not met' do
    with_tmpdir do |dir|
      shell = build_shell(dir:)

      allow(shell).to receive(:execute).with('false', timeout: 10).and_return([1, "fail\n"])
      allow(shell).to receive(:execute).with('true', timeout: 10).and_return([0, "ok\n"])

      expect do
        shell.succeeds('false')
      end.to raise_error(OsVm::CommandFailed, /failed with status 1/)

      expect do
        shell.fails('true')
      end.to raise_error(OsVm::CommandSucceeded, /succeeds with status 0/)
    end
  end

  it 'retries successful command expectations a bounded number of times' do
    with_tmpdir do |dir|
      shell = build_shell(dir:)
      allow(shell).to receive(:sleep)
      allow(shell).to receive(:execute)
        .with('flaky', timeout: 7)
        .and_return([1, 'first'], [2, 'second'], [0, 'ready'])

      expect(
        shell.succeeds_with_retries('flaky', attempts: 3, retry_delay: 2, timeout: 7)
      ).to eq([0, 'ready'])
      expect(shell).to have_received(:sleep).with(2).twice
    end
  end

  it 'raises the last failure after all command attempts are used' do
    with_tmpdir do |dir|
      shell = build_shell(dir:)
      allow(shell).to receive(:sleep)
      allow(shell).to receive(:execute)
        .with('broken', timeout: 10)
        .and_return([1, 'first'], [3, 'last'])

      expect do
        shell.succeeds_with_retries('broken', attempts: 2)
      end.to raise_error(OsVm::CommandFailed, /status 3.*last/m)
      expect(shell).to have_received(:sleep).with(1).once
    end
  end

  it 'retries failed command expectations a bounded number of times' do
    with_tmpdir do |dir|
      shell = build_shell(dir:)
      allow(shell).to receive(:sleep)
      allow(shell).to receive(:execute)
        .with('eventually-down', timeout: 8)
        .and_return([0, 'first'], [0, 'second'], [4, 'stopped'])

      expect(
        shell.fails_with_retries(
          'eventually-down', attempts: 3, retry_delay: 3, timeout: 8
        )
      ).to eq([4, 'stopped'])
      expect(shell).to have_received(:sleep).with(3).twice
    end
  end

  it 'raises the last success after all command attempts are used' do
    with_tmpdir do |dir|
      shell = build_shell(dir:)
      allow(shell).to receive(:sleep)
      allow(shell).to receive(:execute)
        .with('still-running', timeout: 10)
        .and_return([0, 'first'], [0, 'last'])

      expect do
        shell.fails_with_retries('still-running', attempts: 2)
      end.to raise_error(OsVm::CommandSucceeded, /status 0.*last/m)
      expect(shell).to have_received(:sleep).with(1).once
    end
  end

  it 'requires at least one command attempt for both expectations' do
    with_tmpdir do |dir|
      shell = build_shell(dir:)

      %i[succeeds_with_retries fails_with_retries].each do |method|
        [0, -1, 1.5].each do |attempts|
          expect do
            shell.public_send(method, 'never', attempts:)
          end.to raise_error(ArgumentError, /attempts must be a positive integer/)
        end
      end
    end
  end

  it 'waits until commands succeed or fail' do
    with_tmpdir do |dir|
      shell = build_shell(dir:)
      allow(shell).to receive(:sleep)
      allow(shell).to receive(:execute)
        .with('ready', timeout: anything)
        .and_return([1, 'not yet'], [0, 'ready'])
      allow(shell).to receive(:execute)
        .with('down', timeout: anything)
        .and_return([0, 'still up'], [1, 'down'])

      expect(shell.wait_until_succeeds('ready')).to eq([0, 'ready'])
      expect(shell.wait_until_fails('down')).to eq([1, 'down'])
    end
  end
end
