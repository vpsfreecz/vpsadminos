# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsVm::Shell do
  def build_shell(dir:, machine: instance_double(OsVm::Machine, name: 'test', running?: true))
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
