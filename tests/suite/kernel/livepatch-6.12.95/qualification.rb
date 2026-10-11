# Included inside the ordinary main suite's example group. Its boot, exact
# fixture checks, target modules, helpers and kernel-health checks are shared.
require 'shellwords'

QUAL_STATE = '/run/livepatch-qualification'.freeze
QUAL_TRACE = '/sys/kernel/tracing/instances/livepatch_qualification'.freeze
QUAL_CGROUP_TRACE = '/sys/kernel/tracing/instances/livepatch_qualification_cgroup'.freeze
QUAL_SHUTDOWN_TRACE = '/sys/kernel/tracing/instances/livepatch_qualification_shutdown'.freeze
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

def qualification_progress_keys(population)
  %w[wakeups fork_exec] + population.keys.grep(/\Acpu_\d+_(?:progress|perf)\z/)
end

def qualification_progress(before, after)
  qualification_progress_keys(before).each do |key|
    expect(Integer(after.fetch(key))).to be > Integer(before.fetch(key)), key
  end
end

def qualification_wait_for_progress(before, cpu: nil)
  # Publishing follows the wake syscall, not the awakened threads running.
  # A newer elapsed value alone can therefore precede wakeup progress. Keep
  # the original bound, but wait for every counter the hard assertion needs.
  keys = ['elapsed'] + qualification_progress_keys(before)
  reads = keys.map { |key| "$1 == \"#{key}\" { #{key}=$2 }" }
  conditions = keys.map do |key|
    value = key == 'elapsed' ? Float(before.fetch(key)) : Integer(before.fetch(key))
    "#{key} > #{value}"
  end
  unless cpu.nil?
    reads << "$1 == \"cpu_#{cpu}_actual\" { actual_cpu=$2 }"
    conditions << "actual_cpu == #{cpu}"
  end
  machine.wait_until_succeeds(
    "awk -F= '#{reads.join(' ')} END { exit !(#{conditions.join(' && ')}) }' #{QUAL_STATE}/population",
    timeout: 60
  )
end

def qualification_move_population(pid, group)
  # A watchdog stack in smp_call_function_single cannot distinguish one stuck
  # call from a slow succession of calls across the entire task population.
  # Keep a small rolling CSD history on every CPU and dump it on the serial
  # console if migration locks up: the blocked shell cannot collect it later.
  machine.all_succeed(
    'mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing',
    "sysctl -n kernel.softlockup_panic > #{QUAL_STATE}/migration-softlockup-panic",
    "sysctl -n kernel.ftrace_dump_on_oops > #{QUAL_STATE}/migration-trace-dump",
    "mkdir #{QUAL_CGROUP_TRACE}",
    "echo 8 > #{QUAL_CGROUP_TRACE}/buffer_size_kb",
    "echo global > #{QUAL_CGROUP_TRACE}/trace_clock",
    "echo 1 > #{QUAL_CGROUP_TRACE}/events/csd/enable",
    "sysctl -w kernel.ftrace_dump_on_oops=#{File.basename(QUAL_CGROUP_TRACE)}",
    'sysctl -w kernel.softlockup_panic=1',
    "echo 1 > #{QUAL_CGROUP_TRACE}/tracing_on"
  )
  machine.succeeds("echo #{pid} > #{group}/cgroup.procs", timeout: 180)
  # Preserve failed-migration tracing until VM teardown. On success, retain
  # the bounded trace and restore the original policy before subsequent checks.
  machine.all_succeed(
    "echo 0 > #{QUAL_CGROUP_TRACE}/tracing_on",
    "cat #{QUAL_CGROUP_TRACE}/trace",
    "cat #{QUAL_STATE}/migration-softlockup-panic > /proc/sys/kernel/softlockup_panic",
    "cat #{QUAL_STATE}/migration-trace-dump > /proc/sys/kernel/ftrace_dump_on_oops",
    "echo 0 > #{QUAL_CGROUP_TRACE}/events/csd/enable",
    "rmdir #{QUAL_CGROUP_TRACE}"
  )
end

def qualification_shutdown_diagnostics
  # check_mm() can report bad RSS after userspace and its final health check
  # are gone. Keep the return caller and CPU masks on the kernel console,
  # without tracing the workload or changing any health assertion.
  # The counter-sum helper is not traceable on the pinned boot kernel.
  # Observe mm teardown instead, respecting the kernel's probe restrictions.
  probe = 'r:lp95_shutdown/mm_drop __mmdrop state=@system_state:u32 comm=$comm:string ' \
          'online_lo=@__cpu_online_mask:x64 online_hi=@__cpu_online_mask+8:x64 ' \
          'dying_lo=@__cpu_dying_mask:x64 dying_hi=@__cpu_dying_mask+8:x64'
  # SYSTEM_POWER_OFF is 5 on this pinned 6.12.95 boot line. The two mask
  # words cover the qualification's maximum of 128 CPUs.
  event = "#{QUAL_SHUTDOWN_TRACE}/events/lp95_shutdown/mm_drop"
  machine.all_succeed(
    "mkdir #{QUAL_SHUTDOWN_TRACE}",
    "echo 8 > #{QUAL_SHUTDOWN_TRACE}/buffer_size_kb",
    "echo global > #{QUAL_SHUTDOWN_TRACE}/trace_clock",
    "echo '#{probe}' >> /sys/kernel/tracing/kprobe_events",
    "echo 'state == 5' > #{event}/filter",
    "echo 1 > #{event}/enable",
    "echo 1 > #{QUAL_SHUTDOWN_TRACE}/tracing_on",
    # printk mirroring must reach the serial console, not only the dmesg ring.
    'dmesg -n 8',
    'sysctl -w kernel.tracepoint_printk=1',
    'test "$(sysctl -n kernel.tracepoint_printk)" = 1'
  )
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
  # A generic NFQUEUE pre-patch EBUSY does not identify the contended lock.
  # Return probes retain the caller and result without changing admission or
  # retry behavior. Limit records to insmod, not the concurrent churn workers.
  {
    'admit_pernet' => 'down_write_trylock',
    'admit_rtnl' => 'rtnl_trylock',
    'admit_nfnl' => "#{CORRECTED_NAME}:vpsadminos_nfnl_try_unregister"
  }.each do |name, symbol|
    machine.succeeds(
      "echo 'r:lp95_qualification/#{name} #{symbol} ret=$retval:s32 comm=$comm:string' " \
      '>> /sys/kernel/tracing/kprobe_events'
    )
    @qualification_events << name
    machine.all_succeed(
      "echo 'comm == \"insmod\"' > #{QUAL_TRACE}/events/lp95_qualification/#{name}/filter",
      "echo 1 > #{QUAL_TRACE}/events/lp95_qualification/#{name}/enable"
    )
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
  qualification_wait_for_progress(before, cpu: cpu)
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
    begin
      status, output = machine.execute("LC_ALL=C insmod #{CORRECTED_MODULE} 2>&1", timeout: remaining)
    rescue StandardError => e
      # Activation can time out before wait_for_patch is reached. Use its
      # existing bounded reporter before the after-hook releases the workload.
      capture_failed_patch_transition(machine, CORRECTED_NAME, 1)
      raise e
    end
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
    machine.succeeds('cat /sys/kernel/tracing/kprobe_profile')
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
      # A timed-out insmod can still occupy the primary shell. Preserve the
      # qualification trace and state on the already reserved channel first.
      commands = [
        "cat #{QUAL_STATE}/population #{QUAL_TRACE}/trace; ls -R /sys/kernel/livepatch; " \
        'for state_file in /sys/kernel/livepatch/*/enabled /sys/kernel/livepatch/*/transition; do ' \
        'test -f "$state_file" || continue; printf "%s=" "$state_file"; cat "$state_file" 2>&1 || true; done',
        "tail -n 200 #{STRESS_STATE}/output.log; wc -l #{STRESS_STATE}/*.ok; ipset list -name",
        "dmesg | tail -n +#{@example_dmesg_start}"
      ]
      commands.each do |command|
        # Keep a stuck diagnostic child from occupying the reserved shell too.
        machine.execute("timeout -k 1 25 sh -c #{Shellwords.escape(command)}", timeout: 30, shell: :diagnostics)
      end
    end
    cleanup = [
      "touch #{QUAL_STATE}/stop #{QUAL_STATE}/sctp.release #{QUAL_STATE}/tun.stop",
      "echo 1 > /sys/devices/system/cpu/cpu#{QUALIFICATION_CPUS - 1}/online"
    ]
    (@qualification_events || []).reverse_each do |event|
      cleanup << "echo 0 > #{QUAL_TRACE}/events/lp95_qualification/#{event}/enable"
      cleanup << "echo '-:lp95_qualification/#{event}' >> /sys/kernel/tracing/kprobe_events"
    end
    if @qualification_completed
      cleanup.each { |command| machine.execute(command) }
    else
      # Preserve the pre-cleanup snapshot above, then release the failed
      # workload without queuing behind its still-running primary command.
      # One bound covers the whole batch, not 30 seconds per trace event.
      command = ['set +e; cleanup_status=0'] +
                cleanup.map { |step| "#{step} || cleanup_status=$?" } +
                ['exit "$cleanup_status"']
      status, output = machine.execute(
        "timeout -k 1 25 sh -c #{Shellwords.escape(command.join("\n"))}",
        timeout: 30, shell: :diagnostics
      )
      warn "qualification failure cleanup unsuccessful: status=#{status}: #{output}" unless status == 0
    end
  end
rescue StandardError => e
  # A wedged migration may also prevent diagnostics and cleanup from forking.
  # Preserve that example's failure; a successful qualification still requires
  # cleanup to finish without an exception.
  raise if @qualification_completed

  warn "qualification failure diagnostics or cleanup unavailable: #{e.class}: #{e.message}"
end

it 'qualifies the exact predecessor at the declared task, CPU, age and memory envelope' do
  @qualification_completed = false
  # A wedged cgroup migration can also prevent post-failure shell diagnostics.
  # Capture watchdog stacks directly on the retained serial console: the boot
  # loglevel exposes the emergency header but suppresses default-level frames.
  machine.all_succeed('dmesg -n 8', 'sysctl -w kernel.softlockup_all_cpu_backtrace=1')
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
    'test "$(sysctl -n kernel.tracepoint_printk)" = 0',
    'sysctl -w kernel.pid_max=262144 kernel.threads-max=200000 vm.max_map_count=262144'
  )
  memory_kib = Integer(machine.succeeds("awk '/^MemTotal:/ { print $2 }' /proc/meminfo")[1].strip)
  expect(memory_kib).to be_between(QUALIFICATION_MEMORY * 1024 * 0.9, QUALIFICATION_MEMORY * 1024)
  machine.succeeds('cat /proc/cpuinfo /proc/meminfo; cat /sys/devices/system/cpu/online')
  # Standalone qualification cannot rely on earlier main-suite examples to
  # load these types. Kernel module aliases are deliberately denied by the OS.
  machine.succeeds("modprobe -a #{IPSET_HASH_OBJECTS.join(' ')}")
  machine.fails("test -d /sys/module/#{forbidden_name}")
  machine.succeeds("insmod #{previous_module}")
  wait_for_patch(machine, previous_name, 1)

  prepare_transition_state(machine)
  # The ordinary short test's five-minute entry must survive four hours
  # here. Keep the set timeout-enabled (and GC exercised by live churn),
  # but make this preexisting-state witness permanent before aging begins.
  machine.succeeds('ipset -exist add klp_pre_ip 192.0.2.129 timeout 0')
  start_stress(machine)
  machine.succeeds('ipset test klp_pre_ip 192.0.2.129')
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
    # Preserve the inherited memory-node envelope explicitly before adding any
    # tasks. The exact old kernel compares an empty configured v2 mems mask
    # against its nonempty effective mask during CPU hotplug, then needlessly
    # rebinds every VMA once per thread of this shared-mm population. CPU-only
    # hotplug must still offline/online the loaded CPU, not change NUMA policy.
    machine.succeeds(
      "if test -e #{group}/cpuset.mems; then " \
      "nodes=$(cat #{cgroup_root}/cpuset.mems.effective); test -n \"$nodes\"; " \
      "printf '%s\\n' \"$nodes\" > #{group}/cpuset.mems; " \
      "test \"$(cat #{group}/cpuset.mems)\" = \"$nodes\"; " \
      "test \"$(cat #{group}/cpuset.mems.effective)\" = \"$nodes\"; " \
      "cat #{group}/cpuset.mems #{group}/cpuset.mems.effective; fi"
    )
  end
  # Establish the aging cgroup before creating the population. The exact old
  # predecessor can softlock while migrating a large runnable thread group;
  # the full active migration is tested after the correcting replacement.
  machine.succeeds(
    "( sh -ec 'echo $$ > #{groups.last}/cgroup.procs; " \
    "exec #{QUAL_POPULATION} #{QUALIFICATION_TASKS} #{QUALIFICATION_CPUS} 21600 #{QUAL_STATE} 1'; " \
    "echo $? > #{QUAL_STATE}/exit ) > #{QUAL_STATE}/population.log 2>&1 &"
  )
  qualification_wait_for_population
  population = qualification_population
  pid = Integer(population.fetch('pid'))
  machine.succeeds("grep -qx '#{pid}' #{groups.last}/cgroup.procs")
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

  # The full population aged in B under the exact predecessor. Exercise both
  # active migrations only after v7 supplies the perf fix, keeping the helper's
  # original 180-second bound, watchdog policy and failure evidence.
  groups.each do |group|
    qualification_move_population(pid, group)
    machine.succeeds("grep -qx '#{pid}' #{group}/cgroup.procs")
    # Start the freshness wait after the move: a report published during a slow
    # migration is not evidence that counters keep advancing after it returns.
    before = qualification_population
    qualification_wait_for_progress(before)
    qualification_progress(before, qualification_population)
    assert_kernel_healthy(machine, @example_dmesg_start)
  end

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
  machine.succeeds(
    "grep -qx 'tasks=1' #{QUAL_STATE}/population || " \
    "{ cat #{QUAL_STATE}/population; exit 1; }"
  )
  stop_stress(machine)
  consume_transition_state(machine)
  machine.succeeds('ip link del klp_qual_tap')
  groups.each { |group| machine.succeeds("rmdir #{group}") }
  assert_kernel_healthy(machine, @example_dmesg_start)
  qualification_shutdown_diagnostics
  @qualification_completed = true
end
