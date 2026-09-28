# Included inside the ordinary main suite's example group. Its boot, exact
# fixture checks, target modules, helpers and kernel-health checks are shared.
QUAL_STATE = '/run/livepatch-qualification'.freeze
QUAL_TRACE = '/sys/kernel/tracing/instances/livepatch_qualification'.freeze
QUAL_POPULATION = '/etc/livepatch-test/task-population'.freeze

# Reviewed callback registrations in bp-6.12.95-production.patch. Values are
# invocations after successful replacement, then after disable. Do not derive
# expected counts from the module or from the trace being tested.
QUAL_CALLBACKS = {
  'vpsadminos_svm_bump_asid_generation' => [1, 2],
  'vpsadminos_nfs_freeid_pre_patch' => [1, 1],
  'vpsadminos_nfs_freeid_post_patch' => [1, 1],
  'vpsadminos_nfs_freeid_pre_unpatch' => [0, 1],
  'vpsadminos_nfs_freeid_post_unpatch' => [0, 1],
  'vpsadminos_livepatch_pre_patch' => [1, 1],
  'vpsadminos_livepatch_post_patch' => [1, 1],
  'vpsadminos_livepatch_pre_unpatch' => [0, 1],
  'vpsadminos_livepatch_post_unpatch' => [0, 1],
  'vpsadminos_ipset_livepatch_quiesce' => [1, 1],
  'vpsadminos_ipset_livepatch_restore' => [1, 2],
  'vpsadminos_nftables_livepatch_quiesce' => [1, 1],
  'vpsadminos_nftables_livepatch_post_patch' => [1, 1],
  'vpsadminos_nftables_livepatch_pre_unpatch' => [0, 1],
  'vpsadminos_nftables_livepatch_post_unpatch' => [0, 1],
  'vpsadminos_nfqueue_livepatch_quiesce' => [1, 1],
  'vpsadminos_nfqueue_livepatch_restore' => [1, 2],
  'vpsadminos_nfqueue_livepatch_quiesce_blocking' => [0, 1]
}.freeze

def qualification_population
  machine.succeeds("test ! -e #{QUAL_STATE}/exit")
  text = machine.succeeds("cat #{QUAL_STATE}/population")[1]
  values = text.lines.to_h { |line| line.strip.split('=', 2) }
  expect(values.fetch('state')).to eq('running')
  expect(Integer(values.fetch('tasks'))).to eq(QUALIFICATION_TASKS)
  expect(Integer(values.fetch('ready'))).to eq(QUALIFICATION_TASKS - 1)
  expect(Integer(values.fetch('cpus'))).to eq(QUALIFICATION_CPUS)
  expect(values.keys.grep(/\Acpu_\d+_progress\z/).length).to eq(QUALIFICATION_CPUS)
  expect(values.keys.grep(/\Acpu_\d+_perf\z/).length).to eq(QUALIFICATION_CPUS)
  actual_cpus = values.keys.grep(/\Acpu_\d+_actual\z/)
  expect(actual_cpus.length).to eq(QUALIFICATION_CPUS)
  actual_cpus.each { |key| expect(Integer(values.fetch(key))).to eq(Integer(key.split('_')[1])) }
  values
end

def qualification_wait_for_population
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1800
  loop do
    status, output = machine.execute(
      "if test -e #{QUAL_STATE}/exit; then " \
      "cat #{QUAL_STATE}/exit #{QUAL_STATE}/population.log; exit 64; fi; " \
      "grep -qx 'state=running' #{QUAL_STATE}/population && " \
      "grep -qx 'tasks=#{QUALIFICATION_TASKS}' #{QUAL_STATE}/population"
    )
    raise "task population terminated before readiness: #{output}" if status == 64
    return if status == 0

    raise 'task population did not reach the required count within 1800s' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

    sleep 1
  end
end

def qualification_progress(before, after)
  keys = %w[wakeups fork_exec] + before.keys.grep(/\Acpu_\d+_(?:progress|perf)\z/)
  keys.each do |key|
    expect(Integer(after.fetch(key))).to be > Integer(before.fetch(key)), key
  end
end

def qualification_trace_start
  machine.all_succeed(
    'mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing',
    "mkdir #{QUAL_TRACE}",
    "echo 64 > #{QUAL_TRACE}/buffer_size_kb"
  )
  @qualification_events = []
  probes = {
    'start' => 'klp_start_transition',
    'complete' => 'klp_complete_transition',
    'replace' => 'klp_unpatch_replaced_patches'
  }
  QUAL_CALLBACKS.each_key.with_index do |symbol, i|
    probes["cb#{i}"] = "#{CORRECTED_NAME}:#{symbol}"
  end
  probes.each do |name, symbol|
    machine.succeeds("echo 'p:lp95_qualification/#{name} #{symbol}' >> /sys/kernel/tracing/kprobe_events")
    @qualification_events << name
    machine.succeeds("echo 1 > #{QUAL_TRACE}/events/lp95_qualification/#{name}/enable")
  end
  machine.all_succeed("echo > #{QUAL_TRACE}/trace", "echo 1 > #{QUAL_TRACE}/tracing_on")
end

def qualification_trace_counts(disabled:)
  trace = machine.succeeds("cat #{QUAL_TRACE}/trace")[1]
  stats = machine.succeeds("cat #{QUAL_TRACE}/per_cpu/cpu*/stats")[1]
  overruns = stats.scan(/(?:^|\n)(?:commit )?overrun:\s*(\d+)/).flatten
  expect(overruns).not_to be_empty
  expect(overruns.map(&:to_i).uniq).to eq([0])
  expected = { 'start' => disabled ? 2 : 1, 'complete' => disabled ? 2 : 1, 'replace' => 1 }
  QUAL_CALLBACKS.each_with_index do |(symbol, counts), i|
    # kvm_amd is absent on Intel, so its object callbacks must not run.
    # Other callback-bearing modules are loaded in before(:suite).
    expected["cb#{i}"] = if symbol == 'vpsadminos_svm_bump_asid_generation' && QUALIFICATION_VENDOR == 'intel'
                           0
                         else
                           counts[disabled ? 1 : 0]
                         end
  end
  expected.each do |name, count|
    actual = trace.scan(/\b#{Regexp.escape(name)}:/).length
    puts "qualification trace #{name}=#{actual} expected=#{count} disabled=#{disabled}"
    expect(actual).to eq(count), name
  end
end

def qualification_transition(command, name, enabled)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  machine.succeeds(command, timeout: QUALIFICATION_TRANSITION_SECONDS)
  remaining = QUALIFICATION_TRANSITION_SECONDS - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
  expect(remaining).to be > 0
  wait_for_patch(machine, name, enabled, timeout: remaining)
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  puts "qualification transition #{name} enabled=#{enabled} elapsed=#{elapsed} ceiling=#{QUALIFICATION_TRANSITION_SECONDS}"
  expect(elapsed).to be < QUALIFICATION_TRANSITION_SECONDS
end

def qualification_hotplug
  before = qualification_population
  cpu = QUALIFICATION_CPUS - 1
  machine.all_succeed(
    "echo 0 > /sys/devices/system/cpu/cpu#{cpu}/online",
    "test \"$(cat /sys/devices/system/cpu/cpu#{cpu}/online)\" = 0",
    "echo 1 > /sys/devices/system/cpu/cpu#{cpu}/online",
    "test \"$(getconf _NPROCESSORS_ONLN)\" = #{QUALIFICATION_CPUS}"
  )
  machine.wait_until_succeeds(
    "awk -F= '$1 == \"cpu_#{cpu}_actual\" { cpu=$2 } " \
    "$1 == \"cpu_#{cpu}_progress\" { progress=$2 } $1 == \"elapsed\" { elapsed=$2 } " \
    "END { exit !(cpu == #{cpu} && progress > #{before.fetch("cpu_#{cpu}_progress")} && " \
    "elapsed > #{before.fetch('elapsed')}) }' #{QUAL_STATE}/population", timeout: 60
  )
end

def qualification_failed_activation(previous_name)
  hold = '/sys/module/livepatch_test_pernet_hold/parameters/hold'
  held = '/sys/module/livepatch_test_pernet_hold/parameters/held'
  before = qualification_population
  counts = stress_counts(machine)
  begin
    machine.succeeds("echo 1 > #{hold}")
    machine.wait_until_succeeds("test \"$(cat #{held})\" = Y", timeout: 60)
    status, output = machine.execute("insmod #{CORRECTED_MODULE}", timeout: 60)
    expect(status).not_to eq(0), output
    machine.fails("test -d /sys/module/#{CORRECTED_NAME}")
    wait_for_patch(machine, previous_name, 1)
    puts "rejected first activation retains #{previous_name}: #{output}"
  ensure
    machine.succeeds("echo 0 > #{hold}")
  end
  machine.wait_until_succeeds("test \"$(cat #{held})\" = N", timeout: 60)
  sleep 2
  qualification_progress(before, qualification_population)
  wait_for_stress_advance(machine, counts)
  assert_kernel_healthy(machine, @example_dmesg_start)
end

def qualification_activate(previous_name)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  deadline = started + QUALIFICATION_TRANSITION_SECONDS
  attempts = 0
  loop do
    remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
    raise 'qualification activation deadline expired' unless remaining > 0

    attempts += 1
    status, output = machine.execute("LC_ALL=C insmod #{CORRECTED_MODULE} 2>&1", timeout: remaining)
    if status == 0
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(remaining).to be > 0
      wait_for_patch(machine, CORRECTED_NAME, 1, timeout: remaining)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      puts "qualification activation attempts=#{attempts} elapsed=#{elapsed} ceiling=#{QUALIFICATION_TRANSITION_SECONDS}"
      expect(elapsed).to be < QUALIFICATION_TRANSITION_SECONDS
      return
    end

    # Churn can legitimately contend the pre-patch try-lock. A rejection
    # must leave the predecessor enabled; never reverse or force a patch.
    # Keep failed-attempt traces, then count the successful attempt separately.
    puts "qualification activation attempt #{attempts} rejected: #{output}"
    machine.succeeds("cat #{QUAL_TRACE}/trace")
    machine.fails("test -d /sys/module/#{CORRECTED_NAME}")
    remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect(remaining).to be > 0
    wait_for_patch(machine, previous_name, 1, timeout: remaining)
    raise "unexpected activation failure: #{output}" unless output.include?('Device or resource busy')

    machine.succeeds("echo > #{QUAL_TRACE}/trace")
    sleep 1
  end
end

after(:example) do
  if machine.running?
    unless @qualification_completed
      machine.execute("cat #{QUAL_STATE}/population #{QUAL_TRACE}/trace; ls -R /sys/kernel/livepatch", timeout: 30)
      machine.execute("dmesg | tail -n +#{@example_dmesg_start}", timeout: 30)
    end
    machine.execute("touch #{QUAL_STATE}/stop #{QUAL_STATE}/sctp.release #{QUAL_STATE}/tun.stop")
    machine.execute("echo 1 > /sys/devices/system/cpu/cpu#{QUALIFICATION_CPUS - 1}/online")
    (@qualification_events || []).reverse_each do |event|
      machine.execute("echo 0 > #{QUAL_TRACE}/events/lp95_qualification/#{event}/enable")
      machine.execute("echo '-:lp95_qualification/#{event}' >> /sys/kernel/tracing/kprobe_events")
    end
  end
end

it 'qualifies the exact predecessor at the declared task, CPU, age and memory envelope' do
  @qualification_completed = false
  vendor = QUALIFICATION_VENDOR == 'amd' ? 'AuthenticAMD' : 'GenuineIntel'
  kvm = QUALIFICATION_VENDOR == 'amd' ? 'kvm_amd' : 'kvm_intel'
  previous_name = QUALIFICATION_PREDECESSOR == 'v5' ? RELEASED_V5_NAME : PREDECESSOR_NAME
  previous_module = QUALIFICATION_PREDECESSOR == 'v5' ? RELEASED_V5_MODULE : PREDECESSOR_MODULE
  forbidden_name = QUALIFICATION_PREDECESSOR == 'v5' ? PREDECESSOR_NAME : RELEASED_V5_NAME
  machine.all_succeed(
    "grep -Eq '^vendor_id[[:space:]]*: #{vendor}$' /proc/cpuinfo",
    "test \"$(getconf _NPROCESSORS_ONLN)\" = #{QUALIFICATION_CPUS}",
    "modprobe #{kvm}", 'test -c /dev/kvm', KVM_SMOKE,
    "mkdir #{QUAL_STATE}",
    'sysctl -w kernel.pid_max=262144 kernel.threads-max=200000 vm.max_map_count=262144'
  )
  memory_kib = Integer(machine.succeeds("awk '/^MemTotal:/ { print $2 }' /proc/meminfo")[1].strip)
  expect(memory_kib).to be_between(QUALIFICATION_MEMORY * 1024 * 0.9, QUALIFICATION_MEMORY * 1024)
  machine.succeeds('cat /proc/cpuinfo /proc/meminfo; cat /sys/devices/system/cpu/online')
  machine.fails("test -d /sys/module/#{forbidden_name}")
  machine.succeeds("insmod #{previous_module}")
  wait_for_patch(machine, previous_name, 1)

  prepare_transition_state(machine)
  # The ordinary short test's five-minute entry must survive four hours
  # here. Keep the set timeout-enabled (and GC exercised by live churn),
  # but make this preexisting-state witness permanent before aging begins.
  machine.succeeds('ipset -exist add klp_pre_ip 192.0.2.129 timeout 0')
  start_stress(machine)
  prepare_nfs_workload(machine)
  nfs_holder = start_nfs_lock_holder(machine, 'qualification')
  wait_for_nfs_lock(machine, nfs_holder)
  machine.succeeds(
    "( #{V2_RUNTIME} sctp-hold #{QUAL_STATE}/sctp.ready #{QUAL_STATE}/sctp.release; " \
    "echo $? > #{QUAL_STATE}/sctp.exit ) > #{QUAL_STATE}/sctp.log 2>&1 &"
  )
  machine.wait_until_succeeds("test -e #{QUAL_STATE}/sctp.ready", timeout: 120)
  machine.all_succeed('ip tuntap add dev klp_qual_tap mode tap', 'ip link set klp_qual_tap up')
  machine.succeeds(
    "( sh -ec 'while ! test -e #{QUAL_STATE}/tun.stop; do " \
    "#{TAP_WRITE} klp_qual_tap 60 || exit 1; echo 1 >> #{QUAL_STATE}/tun.ok; " \
    "sleep 0.25; done'; echo $? > #{QUAL_STATE}/tun.exit ) > #{QUAL_STATE}/tun.log 2>&1 &"
  )

  cgroup_root = machine.succeeds(
    'if test -e /sys/fs/cgroup/cgroup.controllers; then echo /sys/fs/cgroup; ' \
    'else test -d /sys/fs/cgroup/pids && echo /sys/fs/cgroup/pids; fi'
  )[1].strip
  groups = %w[a b].map { |suffix| "#{cgroup_root}/livepatch_qualification_#{suffix}" }
  groups.each do |group|
    machine.succeeds("mkdir #{group}; if test -e #{group}/pids.max; then echo 200000 > #{group}/pids.max; fi")
  end
  machine.succeeds(
    "( sh -c 'echo $$ > #{groups.first}/cgroup.procs; " \
    "exec #{QUAL_POPULATION} #{QUALIFICATION_TASKS} #{QUALIFICATION_CPUS} 21600 #{QUAL_STATE} 1'; " \
    "echo $? > #{QUAL_STATE}/exit ) > #{QUAL_STATE}/population.log 2>&1 &"
  )
  qualification_wait_for_population
  population = qualification_population
  pid = Integer(population.fetch('pid'))
  machine.succeeds("echo #{pid} > #{groups.last}/cgroup.procs", timeout: 180)
  machine.succeeds("grep -F '/livepatch_qualification_b' /proc/#{pid}/cgroup")
  age_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  network_counts = stress_counts(machine)
  tun_count = Integer(machine.succeeds("wc -l < #{QUAL_STATE}/tun.ok")[1].strip)
  nfs_value = 'qualification-before-activation'
  machine.succeeds("printf '%s' #{nfs_value} > #{NFS_STATE}/mnt/qualification-data")
  loop do
    sleep 60
    current = qualification_population
    qualification_progress(population, current)
    population = current
    wait_for_stress_advance(machine, network_counts)
    network_counts = stress_counts(machine)
    next_tun_count = Integer(machine.succeeds("wc -l < #{QUAL_STATE}/tun.ok")[1].strip)
    expect(next_tun_count).to be > tun_count
    tun_count = next_tun_count
    machine.all_succeed(
      "test ! -e #{QUAL_STATE}/sctp.exit", "test ! -e #{QUAL_STATE}/tun.exit",
      'ipset test klp_pre_ip 192.0.2.129',
      "test \"$(cat #{NFS_STATE}/mnt/qualification-data)\" = #{nfs_value}",
      "sync -f #{NFS_STATE}/mnt/qualification-data"
    )
    status, output = machine.execute("flock -n #{NFS_STATE}/mnt/klp-nfs-lock -c true", timeout: 60)
    expect(status).to eq(1), "aged NFS lock was not retained: #{output}"
    assert_kernel_healthy(machine, @example_dmesg_start)
    age = Process.clock_gettime(Process::CLOCK_MONOTONIC) - age_start
    puts "qualification predecessor=#{previous_name} tasks=#{QUALIFICATION_TASKS} cpus=#{QUALIFICATION_CPUS} age=#{age}"
    break if age >= QUALIFICATION_AGE_SECONDS
  end
  qualification_hotplug
  qualification_failed_activation(previous_name) if QUALIFICATION_FAILURE_RETENTION
  qualification_trace_start
  before = qualification_population
  counts = stress_counts(machine)
  qualification_activate(previous_name)
  wait_for_patch(machine, previous_name, 0)
  machine.fails("test -d /sys/module/#{forbidden_name}")
  machine.succeeds("rmmod #{previous_name}")
  qualification_trace_counts(disabled: false)
  qualification_hotplug
  sleep 2
  qualification_progress(before, qualification_population)
  wait_for_stress_advance(machine, counts)
  machine.succeeds(KVM_SMOKE)
  machine.succeeds("test \"$(cat /proc/#{pid}/patch_state)\" = -1")
  machine.succeeds("test \"$(cat #{NFS_STATE}/mnt/qualification-data)\" = #{nfs_value}")
  expect(Integer(machine.succeeds("wc -l < #{QUAL_STATE}/tun.ok")[1].strip)).to be > tun_count

  qualification_transition("echo 0 > #{patch_dir(CORRECTED_NAME)}/enabled", CORRECTED_NAME, 0)
  qualification_trace_counts(disabled: true)
  machine.succeeds("rmmod #{CORRECTED_NAME}")
  machine.fails("test -d /sys/module/#{CORRECTED_NAME}")
  release_nfs_lock(machine, nfs_holder)
  machine.succeeds("touch #{QUAL_STATE}/sctp.release #{QUAL_STATE}/tun.stop #{QUAL_STATE}/stop")
  machine.wait_until_succeeds(
    "test -e #{QUAL_STATE}/exit && test -e #{QUAL_STATE}/sctp.exit && test -e #{QUAL_STATE}/tun.exit",
    timeout: 180
  )
  %w[exit sctp.exit tun.exit].each do |file|
    machine.succeeds("test \"$(cat #{QUAL_STATE}/#{file})\" = 0")
  end
  machine.succeeds("grep -qx 'state=stopped' #{QUAL_STATE}/population")
  machine.succeeds("grep -qx 'tasks=1' #{QUAL_STATE}/population")
  stop_stress(machine)
  consume_transition_state(machine)
  machine.succeeds('ip link del klp_qual_tap')
  groups.each { |group| machine.succeeds("rmdir #{group}") }
  assert_kernel_healthy(machine, @example_dmesg_start)
  @qualification_completed = true
end
