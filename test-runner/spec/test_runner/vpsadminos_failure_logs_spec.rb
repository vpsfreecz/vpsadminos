# frozen_string_literal: true

require 'open3'
require 'spec_helper'
require_relative '../../../tests/runner/extensions/vpsadminos_logs'

RSpec.describe VpsadminosFailureLogs do
  let(:machine) do
    instance_spy(OsVm::Machine, name: 'machine', running?: true, can_execute?: true)
  end
  let(:script_result) { instance_double(TestRunner::TestScriptResult, unexpected_result?: true) }

  before do
    load File.join(REPO_ROOT, 'tests/runner/extensions/vpsadminos_logs.rb')
  end

  def collect_failure(directory)
    TestRunner::Hook.call(
      :after_test_script_run,
      kwargs: { script_result:, machines: { machine: }, state_dir: directory }
    )
  end

  it 'captures guest diagnostics through the existing failure hook' do
    allow(machine).to receive(:execute)
      .with(described_class.diagnostics_script, timeout: 300)
      .and_return([0, "guest snapshot\n"])

    with_tmpdir do |directory|
      collect_failure(directory)
      expect(machine).to have_received(:execute).with(described_class.diagnostics_script, timeout: 300)
      expect(File.read(File.join(directory, 'machine-failure-diagnostics.log')))
        .to include("machine: machine\nstatus: 0", 'guest snapshot')
    end
  end

  it 'does not run diagnostics for an expected result' do
    allow(script_result).to receive(:unexpected_result?).and_return(false)

    with_tmpdir do |directory|
      collect_failure(directory)
      expect(machine).not_to have_received(:execute)
      expect(Dir.children(directory)).to be_empty
    end
  end

  it 'does not run diagnostics without an available guest shell' do
    allow(machine).to receive(:can_execute?).and_return(false)

    with_tmpdir do |directory|
      collect_failure(directory)
      expect(machine).not_to have_received(:execute)
      expect(Dir.children(directory)).to be_empty
    end
  end

  it 'records collection errors without masking the test failure' do
    allow(machine).to receive(:execute).and_raise(RuntimeError, 'shell unavailable')

    with_tmpdir do |directory|
      expect { collect_failure(directory) }.not_to raise_error
      expect(File.read(File.join(directory, 'machine-failure-diagnostics.log')))
        .to include('diagnostic collection failed: RuntimeError: shell unavailable')
    end
  end

  it 'bounds kernel stack reads and includes guest pressure and thread waits' do
    expect(described_class.diagnostics_script).to include(
      "show_glob '/proc/pressure/*'",
      'ps -eLo pid,tid,stat,wchan:32,comm',
      'head -n 32',
      'timeout 2 cat',
      '/proc/$pid/task/$tid/stack'
    )
  end

  it 'generates valid shell syntax without executing diagnostics on the host' do
    _stdout, stderr, status = Open3.capture3('sh', '-n', stdin_data: described_class.diagnostics_script)

    expect(status).to be_success, stderr
  end
end
