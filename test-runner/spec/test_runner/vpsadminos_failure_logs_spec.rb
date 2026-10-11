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
    allow(machine).to receive(:shells).and_return(OsVm::ShellCollection.new(machine, {}))
    load File.join(REPO_ROOT, 'tests/runner/extensions/vpsadminos_logs.rb')
  end

  def collect_failure(directory)
    TestRunner::Hook.call(
      :after_test_script_run,
      kwargs: { script_result:, machines: { machine: }, state_dir: directory }
    )
  end

  def run_stack_selector(rows)
    selector = described_class.diagnostics_script[/^ps -eLo pid=,tid=,stat=,comm= \|.*?^  done$/m]
    raise 'missing actual kernel stack selector' unless selector

    # Execute only the real selector with synthetic ps rows. The run stub
    # records its arguments; it never reads host proc files or runs a VM.
    stubs = <<~SH
      ps() { cat <<'TASKS'
      #{rows.join("\n")}
      TASKS
      }
      run() { printf '%s\\n' "$*"; }
    SH
    stdout, stderr, status = Open3.capture3('sh', '-c', stubs + selector)
    expect(status).to be_success, stderr
    stdout.lines
  end

  def transfer_context
    filename = File.join(REPO_ROOT, 'tests/suite/osctl/ct-send-recv.nix')
    script = File.read(filename)[/commonScript = ''\n(.*?)^    def self.ensure_cluster_ready/m, 1]
    raise 'missing actual transfer diagnostic helper' unless script

    guest = machine
    context = Object.new
    context.define_singleton_method(:machines) { { machine: guest } }
    context.instance_eval(script, filename)
    context
  end

  it 'does not collect transfer diagnostics on the healthy path or change its options' do
    allow(machine).to receive(:succeeds).with('send sync', timeout: 900).and_return('sent')

    expect(transfer_context.send_succeeds(machine, 'send sync', timeout: 900)).to eq('sent')
    expect(machine).not_to have_received(:execute)
  end

  it 'captures all guest pipe owners on the reserved channel before preserving the transfer error' do
    error = RuntimeError.new('transfer stalled')
    allow(machine).to receive(:succeeds).with('send sync', timeout: 900).and_raise(error)
    allow(machine).to receive(:shells)
      .and_return(OsVm::ShellCollection.new(machine, diagnostics: instance_double(OsVm::Shell)))
    commands = []
    allow(machine).to receive(:execute) do |command, **options|
      expect(options).to eq(timeout: 15, shell: :diagnostics)
      commands << command
      [0, 'snapshot']
    end

    expect { transfer_context.send_succeeds(machine, 'send sync', timeout: 900) }.to raise_error(error)
    expect(commands.length).to eq(4)
    expect(commands.join).to include('/proc/\\[0-9\\]\\*/fd')
    expect(commands.join).not_to include('pgrep')
    commands.each do |command|
      expect(command).to start_with('timeout -k 1 12 sh -c ')
      _stdout, stderr, status = Open3.capture3('sh', '-n', stdin_data: command)
      expect(status).to be_success, stderr
    end
  end

  it 'reports incomplete transfer snapshots without replacing the original error' do
    error = RuntimeError.new('transfer stalled')
    allow(machine).to receive(:succeeds).and_raise(error)
    allow(machine).to receive(:execute).and_return([124, 'partial snapshot'])

    expect do
      expect { transfer_context.send_succeeds(machine, 'send sync') }.to raise_error(error)
    end.to output(/Transfer diagnostic incomplete: status=124/).to_stderr
    expect(machine).to have_received(:execute).exactly(4).times
  end

  it 'uses the ordinary transfer channel when no reserved shell is available' do
    error = RuntimeError.new('transfer stalled')
    allow(machine).to receive(:succeeds).and_raise(error)
    allow(machine).to receive(:execute).and_return([0, 'snapshot'])

    expect { transfer_context.send_succeeds(machine, 'send sync') }.to raise_error(error)
    expect(machine).to have_received(:execute)
      .with(a_string_starting_with('timeout -k 1 12 sh -c '), timeout: 15, shell: nil).exactly(4).times
  end

  it 'does not collect transfer diagnostics from a stopped guest' do
    error = RuntimeError.new('transfer stalled')
    allow(machine).to receive(:succeeds).and_raise(error)
    allow(machine).to receive(:running?).and_return(false)

    expect { transfer_context.send_succeeds(machine, 'send sync') }.to raise_error(error)
    expect(machine).not_to have_received(:execute)
  end

  it 'captures guest diagnostics through the existing failure hook' do
    allow(machine).to receive(:execute)
      .with(described_class.diagnostics_script, timeout: 300, shell: nil)
      .and_return([0, "guest snapshot\n"])

    with_tmpdir do |directory|
      collect_failure(directory)
      expect(machine).to have_received(:execute).with(described_class.diagnostics_script, timeout: 300, shell: nil)
      expect(File.read(File.join(directory, 'machine-failure-diagnostics.log')))
        .to include("machine: machine\nstatus: 0", 'guest snapshot')
    end
  end

  it 'uses the reserved diagnostics channel when the machine provides it' do
    allow(machine).to receive(:shells)
      .and_return(OsVm::ShellCollection.new(machine, diagnostics: instance_double(OsVm::Shell)))
    allow(machine).to receive(:execute)
      .with(described_class.diagnostics_script, timeout: 300, shell: :diagnostics)
      .and_return([0, "reserved snapshot\n"])

    with_tmpdir do |directory|
      collect_failure(directory)
      expect(machine).to have_received(:execute)
        .with(described_class.diagnostics_script, timeout: 300, shell: :diagnostics)
      expect(File.read(File.join(directory, 'machine-failure-diagnostics.log')))
        .to include("machine: machine\nstatus: 0", 'reserved snapshot')
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

  it 'captures running module loaders before other blocked threads within the cap' do
    rows = (1..33).map { |pid| "#{pid} #{pid} D blocked" }
    rows.push('25951 25951 R insmod', '26000 26000 R modprobe', '999 999 R user')

    output = run_stack_selector(rows)
    expect(output.length).to eq(32)
    expect(output.first).to include('/proc/25951/task/25951/stack')
    expect(output[1]).to include('/proc/26000/task/26000/stack')
    expect(output.join).to include('/proc/30/task/30/stack')
    expect(output.join).not_to include('/proc/31/task/31/stack', '/proc/999/')
  end

  it 'does not duplicate a blocked module loader or capture unrelated running tasks' do
    output = run_stack_selector(['1 1 D blocked', '25951 25951 D insmod', '999 999 R user'])

    expect(output.length).to eq(2)
    expect(output.first).to include('/proc/25951/task/25951/stack')
    expect(output.last).to include('/proc/1/task/1/stack')
    expect(output.join).not_to include('/proc/999/')
  end

  it 'generates valid shell syntax without executing diagnostics on the host' do
    _stdout, stderr, status = Open3.capture3('sh', '-n', stdin_data: described_class.diagnostics_script)

    expect(status).to be_success, stderr
  end
end
