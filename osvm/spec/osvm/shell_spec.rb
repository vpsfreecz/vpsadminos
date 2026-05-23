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
end
