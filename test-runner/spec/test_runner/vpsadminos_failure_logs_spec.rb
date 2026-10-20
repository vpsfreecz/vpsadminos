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

  it 'collects a stop failure without overwriting script failure diagnostics' do
    allow(machine).to receive(:execute).and_return([0, "shutdown state\n"])

    Dir.mktmpdir do |directory|
      original = File.join(directory, 'machine-failure-diagnostics.log')
      File.write(original, 'original script failure')
      TestRunner::Hook.call(
        :after_machine_stop_failure,
        kwargs: { machine:, state_dir: directory, error: RuntimeError.new('stop failed') }
      )

      expect(File.read(original)).to eq('original script failure')
      expect(File.read(File.join(directory, 'machine-shutdown-failure-diagnostics.log')))
        .to include('shutdown state')
    end
    expect(machine).to have_received(:execute).with(described_class.diagnostics_script, timeout: 300, shell: nil)
  end

  it 'does not collect stop diagnostics without an executable guest shell' do
    allow(machine).to receive(:can_execute?).and_return(false)

    Dir.mktmpdir do |directory|
      TestRunner::Hook.call(:after_machine_stop_failure, kwargs: { machine:, state_dir: directory })
      expect(Dir.children(directory)).to be_empty
    end
    expect(machine).not_to have_received(:execute)
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
    source = File.read(filename)
    script = source[/commonScript = ''\n(.*?)^    def self.ensure_cluster_ready/m, 1]
    raise 'missing actual transfer diagnostic helper' unless script

    clone_script = source[/^          def self.collect_authorization_diagnostics\n.*?(?=^          def self.reset_authorization_state)/m]
    raise 'missing actual authorization diagnostic helpers' unless clone_script

    guest = machine
    context = Object.new
    context.define_singleton_method(:machines) { { machine: guest } }
    context.define_singleton_method(:node1) { guest }
    context.instance_eval(script, filename)
    context.instance_eval(clone_script, filename)
    context
  end

  def run_runner_selector(rows)
    script = described_class.diagnostics_script
    selector = script.split("section 'container runner bootstrap state (at most 8 processes)'\n", 2).last&.split("\n\n", 2)&.first
    raise 'missing actual runner selector' unless selector&.start_with?('ps -eo')

    # Use synthetic ps rows and record the proc paths without reading the host.
    stubs = <<~SH
      ps() { cat <<'TASKS'
      #{rows.join("\n")}
      TASKS
      }
      run() { printf '%s\n' "$*"; }
    SH
    stdout, stderr, status = Open3.capture3('sh', '-c', stubs + selector)
    expect(status).to be_success, stderr
    stdout.lines
  end

  it 'captures runnable and sleeping bootstrap runners but not unrelated Ruby processes' do
    rows = [
      '14106 Rl osctld-ct-runne',
      '14107 Sl osctld-ct-runner',
      '14108 Rl ruby',
      '14109 Rl osctld:main',
      '14110 Rl osctld-ct-runner-extra'
    ]
    output = run_runner_selector(rows)

    expect(output.length).to eq(2)
    expect(output.first).to include(
      'timeout 2 cat /proc/14106/stat /proc/14106/status /proc/14106/schedstat',
      '/proc/14106/cgroup /proc/14106/syscall /proc/14106/wchan /proc/14106/stack'
    )
    expect(output.last).to include('/proc/14107/stat')
    expect(output.join).not_to include('/proc/14108/', '/proc/14109/', '/proc/14110/')
  end

  it 'bounds runner bootstrap snapshots before diagnostic RPCs create more workers' do
    output = run_runner_selector((1..12).map { |pid| "#{pid} Rl osctld-ct-runne" })

    expect(output.length).to eq(8)
    expect(output.last).to include('/proc/8/stat')
    expect(output.join).not_to include('/proc/9/', '/proc/12/')
    script = described_class.diagnostics_script
    expect(script.index("section 'container runner bootstrap state")).to be < script.index('timeout 10 osctl debug threads ls')
  end

  it 'preserves the healthy authorization clone path without collecting diagnostics' do
    allow(machine).to receive(:succeeds).with('send clone').and_return('sent')
    context = transfer_context
    allow(context).to receive(:collect_authorization_diagnostics)

    expect(context.send_clone_with_diagnostics('send clone')).to eq('sent')
    expect(machine).not_to have_received(:execute)
    expect(context).not_to have_received(:collect_authorization_diagnostics)
  end

  it 'keeps first-transfer and authorization diagnostics without replacing the clone failure' do
    error = RuntimeError.new('clone stalled')
    allow(machine).to receive(:succeeds).with('send clone').and_raise(error)
    allow(machine).to receive(:execute).and_return([0, 'snapshot'])
    context = transfer_context
    allow(context).to receive(:collect_authorization_diagnostics).and_raise('snapshot failed')

    expect { context.send_clone_with_diagnostics('send clone') }.to raise_error(error)
    expect(machine).to have_received(:execute).exactly(4).times
    expect(context).to have_received(:collect_authorization_diagnostics).once
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

  it 'bounds kernel-stack collection to blocked and ZFS sync tasks' do
    script = described_class.diagnostics_script

    expect(script).to include('ps -eo pid=,stat=,comm=')
    expect(script).to include('$2 ~ /^D/ || $3 == "dp_sync_taskq"')
    expect(script).to include('head -n 16')
    expect(script).to include('timeout 2 cat "/proc/$pid/stack" 2>&1')
  end

  it 'captures bounded host route and link state before teardown' do
    script = described_class.diagnostics_script

    expect(script).to include('timeout 10 ip -o link show')
    expect(script).to include('timeout 10 ip -4 addr show')
    expect(script).to include('timeout 10 ip -4 rule show')
    expect(script).to include('timeout 10 ip -4 route show table all')
    expect(script.index('timeout 10 ip -o link show')).to be < script.index('run dmesg -T')
  end

  it 'captures bounded public daemon-thread stacks before container queries' do
    script = described_class.diagnostics_script

    expect(script).to include("section 'osctld Ruby thread backtraces'")
    expect(script).to include('timeout 10 osctl debug threads ls 2>&1')
    expect(script).to include("printf 'osctl debug threads ls status=%s\\n' \"$?\"")
    expect(script.index('timeout 10 osctl debug threads ls')).to be < script.index('timeout 10 osctl ct ls')
  end

  it 'retains collected output in the normal failure artifact' do
    output = "===== /proc/123/stack (D zfs) =====\n[<0>] zio_wait\n"
    output += "===== osctld Ruby thread backtraces =====\nfrontend.rb:321:in `readline'\n"
    output += "osctl debug threads ls status=0\n"

    allow(machine).to receive(:execute).and_return([0, output])

    Dir.mktmpdir do |dir|
      path = File.join(dir, 'machine-failure-diagnostics.log')
      described_class.collect(machine, path)
      expect(File.read(path)).to include('status: 0', output)
    end

    expect(machine).to have_received(:execute).with(
      include('timeout 2 cat "/proc/$pid/stack"', 'timeout 10 osctl debug threads ls'),
      timeout: 300,
      shell: nil
    )
  end

  it 'bounds read-only guest network and root-aware resolver snapshots' do
    script = described_class.diagnostics_script

    expect(script).to include('timeout 10 osctl ct ls -H -o pool,id,state,init_pid')
    expect(script).to include('$3 == "running" && $4 ~ /^[1-9][0-9]*$/')
    expect(script).to include('timeout 5 nsenter -t "$pid" -n -- sh -c')
    expect(script).to include('ip -4 addr show; ip -6 addr show')
    expect(script).to include('ip -4 route show table all; ip -6 route show table all')
    expect(script).to include('timeout 2 nsenter -t "$pid" -m -r -- /bin/sh -c')
    expect(script).to include('PATH=/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin')
    expect(script).not_to include('osctl ct exec')
  end

  it 'uses supported container listing columns and retains the PID query status' do
    script = described_class.diagnostics_script

    expect(script).to include('timeout 10 osctl ct ls -H -o pool,id,state,init_pid 2>/dev/null || true')
    expect(script).to include("printf 'guest PID listing status=%s\\n' \"$?\" >&2")
    expect(script).not_to include('init-pid', 'log-file')
  end

  it 'retains guest resolver configuration and DHCP client/package identity without changing them' do
    script = described_class.diagnostics_script

    expect(script).to include('guest resolver/network/package identity (init $pid)')
    expect(script).to include('/etc/os-release /etc/resolv.conf /etc/nsswitch.conf')
    expect(script).to include('/etc/network/interfaces /etc/network/interfaces.d/*')
    expect(script).to include('for client in dhcpcd dhclient udhcpc; do command -v "$client"; done')
    expect(script).to include('if command -v dpkg-query >/dev/null 2>&1; then')
    expect(script).to include('dpkg-query -s ifupdown dhcpcd-base isc-dhcp-client udhcpc systemd-resolved')
    expect(script).to include("printf 'guest resolver/network/package snapshot status=%s\\n' \"$?\"")
    expect(script).not_to include('apt-get', 'ifup eth', 'dhclient eth', 'dhcpcd eth')
  end

  it 'retains bounded recent networking journals without filtering by a possibly lost boot ID' do
    script = described_class.diagnostics_script

    expect(script).to include('guest networking journal (init $pid)')
    expect(script).to include('timeout -k 1 5 nsenter -t "$pid" -m -r -- /bin/sh -c')
    expect(script).to include('if command -v journalctl >/dev/null 2>&1; then')
    expect(script).to include('journalctl --no-pager -n 80 -o short-iso-precise')
    expect(script).to include('-u networking.service -u systemd-networkd.service')
    expect(script).to include('-u NetworkManager.service -u "dhcpcd*" -u "ifup*"')
    expect(script).to include("printf 'guest networking journal snapshot status=%s\\n' \"$?\"")
    expect(script).not_to include('journalctl -b', 'systemctl restart', 'systemctl reset-failed')
  end
end
