# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TestRunner::Executor do
  def build_executor
    described_class.new([], state_dir: '/tmp/os-test-runner', jobs: 1)
  end

  it 'derives unique state directories from the test path, not only the display name' do
    executor = build_executor
    first = instance_double(TestRunner::Test, name: 'v1', path: 'osctl/ct-exec-v1')
    second = instance_double(TestRunner::Test, name: 'v1', path: 'osctl/ct-runscript-v1')

    expect(executor.send(:test_state_dir, first)).not_to eq(executor.send(:test_state_dir, second))
  end

  it 'uses the test path for multicast reservation keys' do
    test = build_test(path: 'osctl/ct-exec-v1', name: 'v1')
    script = test.test_scripts['default']
    executor = described_class.new([script], state_dir: '/tmp/os-test-runner', jobs: 1)
    dir = executor.send(:test_state_dir, test)
    FileUtils.mkdir_p(dir)
    reader, writer = IO.pipe
    writer_copy = writer.dup
    child_pid = fork { exit 0 }
    actual_wait = Process.method(:wait)

    Thread.new do
      writer_copy.close
    end

    allow(IO).to receive(:pipe).and_return([reader, writer])
    allow(Process).to receive(:fork).and_return(child_pid)
    allow(Process).to receive(:wait) { |pid| actual_wait.call(pid) }
    allow(OsVm::PortReservation).to receive(:get_ports).and_return([10_000, 10_001, 10_002, 10_003])
    allow(OsVm::PortReservation).to receive(:release_ports)
    allow(executor).to receive(:log)

    executor.send(:run_test, test, [script], prefix: '[1/1]')

    expect(OsVm::PortReservation).to have_received(:get_ports).with(key: 'test:osctl/ct-exec-v1', size: 4)
    expect(OsVm::PortReservation).to have_received(:release_ports).with(key: 'test:osctl/ct-exec-v1')
  end
end
