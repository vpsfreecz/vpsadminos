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
    machine = instance_double(OsVm::Machine, name: 'machine')
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
      timeout: 300
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
end
