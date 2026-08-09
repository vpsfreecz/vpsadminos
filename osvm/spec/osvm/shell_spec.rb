# frozen_string_literal: true

require 'spec_helper'

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
