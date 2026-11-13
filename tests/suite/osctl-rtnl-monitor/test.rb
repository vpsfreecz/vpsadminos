require 'json'

describe 'diagnostic RTNL monitor on the selected stable kernel', order: :defined do
  before(:context) do
    machine.start
    machine.wait_for_osctl_pool('tank')
    machine.wait_until_online
    machine.succeeds('test "$(uname -r)" = 6.12.117')
    machine.succeeds('test "$(cat /run/osctl/cgroup.version)" = 2')
    machine.succeeds('modprobe rtnl_fixture')
    machine.succeeds('test -w /proc/rtnl_monitor_fixture/release')
    machine.succeeds('osctl-rtnl-monitor --help')
    machine.succeeds('osctl-rtnl-monitor --version')
    machine.succeeds('sv stop osctl-rtnl-monitor')
    machine.succeeds('sv stop osctl-rtnl-monitor-roots')
    _, startup = machine.succeeds('python3 /etc/rtnl-monitor-test.py startup', timeout: 15)
    puts startup
    machine.succeeds('test ! -e /run/rtnl-monitor-test/monitor.prom')
  end

  it 'runs the packaged inventory and monitor services against one real container' do
    _, output = machine.succeeds('python3 /etc/rtnl-monitor-service-smoke.py', timeout: 120)
    result = JSON.parse(output)
    expect(result.fetch('real_container')).to eq('rtnl-smoke')
    expect(result.fetch('snapshot').fetch('assessment_valid')).to be(true)
    puts JSON.generate(result)
    machine.succeeds('test ! -e /run/osctl-rtnl-monitor/roots.json')
    machine.succeeds('test ! -e /run/metrics/osctl-rtnl-monitor.prom')
  end

  {
    'contention' => 'alarms before release across three roots, counting nested leaves once',
    'safety' => 'expires a maximum hold without userspace release and rejects excessive durations',
    'variants' => 'removes calls on all blocking returns, fatal signals and task exits',
    'mapping' => 'rejects old run tokens and resolves a recreated root without misattribution',
    'stale' => 'reports unknown when the inventory heartbeat expires',
    'overflow' => 'keeps map overflow visibly unknown for the attach epoch',
    'unavailable' => 'fails visibly on root limits and a missing required attach target',
    'diagnostics' => 'bounds optional stacks and advances textfile snapshots under output backpressure',
    'overhead' => 'reports paired off/on costs and CPU-busy false-alarm controls'
  }.each do |scenario, description|
    it description do
      machine.succeeds('sv status osctl-rtnl-monitor | grep -q "^down:"')
      machine.succeeds('sv status osctl-rtnl-monitor-roots | grep -q "^down:"')
      _, output = machine.succeeds(
        'RTNL_MONITOR_BPF_OBJECT=$(cat /etc/rtnl-monitor-test-bpf-object) ' \
        "python3 /etc/rtnl-monitor-test.py #{scenario}",
        timeout: 90
      )
      result = JSON.parse(output)
      expect(result.fetch('scenario')).to eq(scenario)
      # Preserve measured rows and frame evidence in the ordinary test log.
      puts JSON.generate(result)
      machine.succeeds('test ! -e /run/rtnl-monitor-test/monitor.prom')
    end
  end

  after(:context) do
    machine.succeeds('printf release > /proc/rtnl_monitor_fixture/release')
    machine.succeeds('rmmod rtnl_fixture')
    machine.succeeds('test ! -e /proc/rtnl_monitor_fixture')
    _, output = machine.succeeds('dmesg')
    expect(output).not_to match(/BUG:|Oops:|WARNING:.*(?:rtnl|bpf)|possible recursive locking/)
  end
end
