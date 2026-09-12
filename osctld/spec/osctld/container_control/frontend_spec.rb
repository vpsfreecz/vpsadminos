# frozen_string_literal: true

require 'osctld/container_control/command'
require 'osctld/container_control/frontend'
require 'osctld/container_control/result'

RSpec.describe OsCtld::ContainerControl::Frontend do
  subject(:frontend) { described_class.new(nil, nil) }

  def read_child(timeout: 2, &operation)
    reader, writer = IO.pipe
    pid = Process.fork do
      reader.close
      operation.call(writer)
      writer.close
      exit!(0)
    end
    writer.close
    deadline = timeout && (Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout)
    frontend.send(:read_fork_result, reader, pid, deadline)
  end

  it 'reads a response split across writes and waits for the child' do
    result = read_child do |io|
      io.write('{"status":true,')
      sleep(0.01)
      io.write("\"output\":42}\n")
    end
    expect(result.ok?).to be(true)
    expect(result.data).to eq(42)
  end

  it 'preserves callers without a deadline and their final unterminated line' do
    result = read_child(timeout: nil) { |io| io.write('{"status":true,"output":17}') }
    expect(result.data).to eq(17)
  end

  it 'reports EOF as a runner failure' do
    result = read_child { |_io| nil }
    expect(result.ok?).to be(false)
    expect(result.user_runner?).to be(true)
  end

  [false, true].each do |respond|
    it "bounds waiting for a stuck child (response sent: #{respond})" do
      reapers = []
      allow(Process).to receive(:detach).and_wrap_original do |original, pid|
        original.call(pid).tap { |thread| reapers << thread }
      end
      expect do
        read_child(timeout: 0.1) do |io|
          io.write("{\"status\":true}\n") if respond
          sleep(60)
        end
      end.to raise_error(OsCtld::ContainerControl::UserRunnerError, /timed out/)
      expect(reapers.length).to eq(1)
      expect(reapers.first.join(2)).not_to be_nil
      expect(reapers.first.value.termsig).to eq(Signal.list.fetch('KILL'))
    end
  end

  it 'bounds memory consumed by a faulty runner' do
    expect { read_child { |io| io.write('x' * 70_000) } }
      .to raise_error(OsCtld::ContainerControl::UserRunnerError, /response too large/)
  end
end
