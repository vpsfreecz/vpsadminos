require 'json'
require 'securerandom'

describe 'active RTNL watchdog and guarded oomd integration', order: :defined do
  before(:context) do
    machine.start
    machine.wait_for_osctl_pool('tank')
    machine.wait_until_online
    machine.succeeds('test "$(uname -r)" = 6.12.117')
    machine.succeeds('test "$(cat /run/osctl/cgroup.version)" = 2')
    machine.succeeds('sv stop rtnl-watchdog')
    machine.succeeds('test ! -d /service/osctl-oomd')
    machine.succeeds('modprobe rtnl_fixture')
    machine.succeeds('rtnl-watchdog --help')
    machine.succeeds('rtnl-watchdog --version')
    _, output = machine.succeeds('python3 /etc/rtnl-watchdog-test/fixture.py startup', timeout: 15)
    puts output
  end

  {
    'pending' => 'reports distress while the real netlink send remains blocked and matches recovery',
    'first_probe' => 'reports a first-ever blocked probe without requiring an earlier success',
    'supervisor' => 'retains one inherited-lock helper across ticks and an actual supervisor restart',
    'namespace' => 'rejects a different network namespace without reporting a successful probe',
    'backpressure' => 'keeps fresh state and single-flight admissions with undrained output',
    'overhead' => 'measures warmed default observer and helper CPU with tick-resolution brackets'
  }.each do |scenario, description|
    it description do
      _, output = machine.succeeds("python3 /etc/rtnl-watchdog-test/fixture.py #{scenario}", timeout: 60)
      expect(JSON.parse(output).fetch('scenario')).to eq(scenario)
      puts output
    end
  end

  it 'uses the installed lean stream and rejects stale or missing guarded daemon identities' do
    @lean_guard_attempted = true
    @lean_guard_complete = false
    @lean_guard_diagnostics = "rtnl-watchdog-#{SecureRandom.hex(8)}"
    begin
      _, output = machine.succeeds(
        "RTNL_WATCHDOG_DIAGNOSTICS=/run/osvm/shared-dir/#{@lean_guard_diagnostics}.jsonl " \
        'python3 /etc/rtnl-watchdog-test/runtime.py lean_guard', timeout: 120
      )
      expect(JSON.parse(output).fetch('scenario')).to eq('lean_guard')
      latest = File.join(machine.__send__(:shared_dir).host_path, "#{@lean_guard_diagnostics}.current.json")
      expect(JSON.parse(File.read(latest))).to include('phase' => 'lean_guard', 'edge' => 'returned')
      puts output
      @lean_guard_complete = true
    ensure
      unless @lean_guard_complete
        # Read the host side of the existing shared mount even if shell
        # synchronization failed. Never issue a second guest command here.
        %w[jsonl current.json snapshot.jsonl].each do |suffix|
          path = File.join(machine.__send__(:shared_dir).host_path, "#{@lean_guard_diagnostics}.#{suffix}")
          begin
            puts "case 7 evidence #{path}:\n#{File.binread(path, 256 * 1024)}"
          rescue StandardError => e
            puts "case 7 evidence unavailable #{path}: #{e.class}: #{e.message}"
          end
        end
      end
    end
  end

  it 'applies raw predicates and fresh episode evidence while preserving ordinary stop scores' do
    _, output = machine.succeeds('rtnl-watchdog-policy-test', timeout: 30)
    expect(JSON.parse(output).fetch('mode')).to eq('controlled_inputs_only')
    puts output
  end

  it 'dispatches a second guarded action while the first remains blocked and suppresses duplicates' do
    if @lean_guard_attempted && !@lean_guard_complete
      raise "case 7 incomplete; no dispatch attempted; retain unknown guest effects; evidence #{@lean_guard_diagnostics}"
    end

    _, output = machine.succeeds('python3 /etc/rtnl-watchdog-test/runtime.py dispatch', timeout: 120)
    expect(JSON.parse(output).fetch('scenario')).to eq('dispatch')
    puts output
  end

  after(:context) do
    machine.succeeds('printf release > /proc/rtnl_monitor_fixture/release')
    machine.succeeds('sv stop rtnl-watchdog')
    machine.succeeds('rmmod rtnl_fixture')
    _, output = machine.succeeds('dmesg')
    expect(output).not_to match(/BUG:|Oops:|WARNING:.*rtnl|possible recursive locking/)
  end
end
