# Included inside the ordinary main suite's example group. Its boot, exact
# fixture checks, target modules, helpers and kernel-health checks are shared.
require 'shellwords'
require 'base64'
require 'digest'
require 'stringio'
require 'zlib'

QUAL_STATE = '/run/livepatch-qualification'.freeze
QUAL_TRACE = '/sys/kernel/tracing/instances/livepatch_qualification'.freeze
QUAL_CGROUP_TRACE = '/sys/kernel/tracing/instances/livepatch_qualification_cgroup'.freeze
QUAL_SHUTDOWN_TRACE = '/sys/kernel/tracing/instances/livepatch_qualification_shutdown'.freeze
QUAL_DYING_TRACE = '/sys/kernel/tracing/instances/livepatch_qualification_dying'.freeze
QUAL_POPULATION = '/etc/livepatch-test/task-population'.freeze

# Frozen a2384967 ELF/BTF: sched_cpu_dying+0xc3 calls dl_server_stop while
# holding rq's lock, after the warning and before dequeue. RDI is fair_server,
# RBX is rq. These offsets belong only to the notes-guarded frozen kernel.
QUAL_DYING_FIELDS = {
  'server' => '%di:x64', 'rq' => '%bx:x64', 'entity_rq' => '+216(%di):x64',
  'parent_color' => '+0(%di):x64', 'nr_running' => '+4(%bx):u32',
  'nr_pinned' => '+3312(%bx):u32', 'cfs_nr' => '+144(%bx):u32',
  'cfs_queued' => '+148(%bx):u32', 'cfs_runnable' => '+152(%bx):u32',
  'cfs_delayed' => '+164(%bx):u32', 'rt_nr' => '+2256(%bx):u32',
  'dl_nr' => '+2320(%bx):u32', 'rq_cpu' => '+2920(%bx):s32',
  'rq_online' => '+2924(%bx):s32', 'flags' => '+84(%di):x32'
}.freeze

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

def qualification_hotplug(phase:)
  before = qualification_population
  cpu = QUALIFICATION_CPUS - 1
  puts "qualification hotplug phase=#{phase} cpu=#{cpu} starting"
  machine.all_succeed(
    "echo 0 > /sys/devices/system/cpu/cpu#{cpu}/online",
    "test \"$(cat /sys/devices/system/cpu/cpu#{cpu}/online)\" = 0",
    "echo 1 > /sys/devices/system/cpu/cpu#{cpu}/online",
    "test \"$(getconf _NPROCESSORS_ONLN)\" = #{QUALIFICATION_CPUS}"
  )
  qualification_wait_for_progress(before, cpu: cpu)
  # Retain the example-wide baseline: a warning before replacement must fail
  # the predecessor phase, even if both sysfs writes and workload progress pass.
  puts "qualification hotplug phase=#{phase} cpu=#{cpu} checking cumulative kernel health"
  assert_kernel_healthy(machine, @example_dmesg_start)
  puts "qualification hotplug phase=#{phase} cpu=#{cpu} complete"
end

def qualification_dying_records(trace)
  rows = trace.lines.select { |line| line.include?('scheduler_dying:') }
  raise 'missing locked CPU127 observation' if rows.empty?

  rows.each do |line|
    # Kallsyms' displayed span can include alignment beyond ELF st_size.
    # It is presentation only; the notes-bound probe address is fixed above.
    header = %r{\[(\d+)\].*?\s(\d+\.\d+): scheduler_dying: \(sched_cpu_dying\+0xc3/0x[0-9a-fA-F]+\)}.match(line)
    pairs = line.scan(/\b([a-z_]+)=(0x[0-9a-f]+|\d+)\b/i)
    unless header && Integer(header[1]) == 127 && Float(header[2]) > 0 &&
           pairs.map(&:first).sort == QUAL_DYING_FIELDS.keys.sort
      raise "unbound or incomplete dying observation: #{line}"
    end

    values = pairs.to_h.transform_values { |value| Integer(value, 0) }
    unless %w[server rq entity_rq parent_color].all? { |key| values.fetch(key) > 0 } &&
           values.fetch('entity_rq') == values.fetch('rq') &&
           values.fetch('server') == values.fetch('rq') + 2408 &&
           values.fetch('rq_cpu') == 127 && [0, 1].include?(values.fetch('rq_online')) &&
           values.fetch('nr_running') > 0 && values.fetch('flags').allbits?(16)
      raise "invalid runqueue/entity identity: #{line}"
    end

    # on_dl_rq() is !RB_EMPTY_NODE(): the node's parent/color equals its own
    # address only when empty. Active alone does not establish membership.
    flags = values.fetch('flags')
    puts "scheduler dying queued=#{values.fetch('parent_color') != values.fetch('server')} " \
         "throttled=#{flags & 1} active=#{(flags >> 5) & 1} defer=#{(flags >> 6) & 1} " \
         "armed=#{(flags >> 7) & 1} defer_running=#{(flags >> 8) & 1}: #{line.strip}"
  end
  rows.length
end

def qualification_dying_selected?
  QUALIFICATION_VENDOR == 'amd' && QUALIFICATION_PREDECESSOR == 'v5' &&
    QUALIFICATION_CPUS == 128 && QUALIFICATION_MEMORY == 16_384 && QUALIFICATION_TASKS == 100_000
end

def qualification_prepare_dying
  return unless qualification_dying_selected?
  raise 'scheduler diagnostic already prepared or uncertain' if @qualification_dying

  state = @qualification_dying = {
    instance: :none, event: :none, arm: :none, recording: :unknown,
    prepared: false, release_attempted: false, released: false
  }
  event = "#{QUAL_DYING_TRACE}/events/lp95_dying/scheduler_dying"
  begin
    machine.succeeds(
      'test "$(sha256sum /sys/kernel/notes | cut -d\' \' -f1)" = ' \
      '1e4432629c0f1a1e9c6b175495217859279f98ded2beca091834ec059e42108a', timeout: 10
    )
    machine.succeeds('test "$(uname -r)" = 6.12.95.5', timeout: 10)
    address = symbol_address(machine, 'sched_cpu_dying').to_i(16) + 0xc3
    probe = "p:lp95_dying/scheduler_dying 0x#{address.to_s(16)} " \
            "#{QUAL_DYING_FIELDS.map { |name, fetch| "#{name}=#{fetch}" }.join(' ')}"
    machine.succeeds('mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing', timeout: 10)
    machine.succeeds("test ! -e #{QUAL_DYING_TRACE}", timeout: 10)
    machine.succeeds('test ! -e /sys/kernel/tracing/events/lp95_dying/scheduler_dying', timeout: 10)
    state[:instance] = :possible
    machine.succeeds("mkdir #{QUAL_DYING_TRACE}", timeout: 10)
    state[:instance] = :owned
    machine.succeeds("test \"$(cat #{QUAL_DYING_TRACE}/current_tracer)\" = nop", timeout: 10)
    state[:recording] = :possible
    machine.succeeds("echo 0 > #{QUAL_DYING_TRACE}/tracing_on", timeout: 10)
    machine.succeeds("test \"$(cat #{QUAL_DYING_TRACE}/tracing_on)\" = 0", timeout: 10)
    state[:recording] = :off
    [
      "echo 64 > #{QUAL_DYING_TRACE}/buffer_size_kb",
      "echo mono > #{QUAL_DYING_TRACE}/trace_clock",
      "echo 0 > #{QUAL_DYING_TRACE}/options/overwrite",
      "echo 80000000,00000000,00000000,00000000 > #{QUAL_DYING_TRACE}/tracing_cpumask"
    ].each { |command| machine.succeeds(command, timeout: 10) }
    state[:event] = :possible
    machine.succeeds("echo '#{probe}' >> /sys/kernel/tracing/kprobe_events", timeout: 10)
    state[:event] = :owned
    [
      "echo 'rq_cpu == 127' > #{event}/filter",
      "echo > #{QUAL_DYING_TRACE}/trace"
    ].each { |command| machine.succeeds(command, timeout: 10) }
    state[:arm] = :possible
    machine.succeeds("echo 1 > #{event}/enable", timeout: 10)
    machine.succeeds("test \"$(cat #{event}/enable)\" = 1", timeout: 10)
    machine.succeeds("test \"$(cat #{QUAL_DYING_TRACE}/tracing_on)\" = 0", timeout: 10)
    machine.succeeds("test \"$(cat #{QUAL_DYING_TRACE}/current_tracer)\" = nop", timeout: 10)
    state[:arm] = :armed
    state[:prepared] = true
    puts "scheduler dying prepared site=0x#{address.to_s(16)} CPU127 mono nop enabled=1 recording=0; frozen notes verified"
  ensure
    unless state[:prepared]
      warn 'scheduler diagnostic INCOMPLETE: early preparation did not complete'
      begin
        qualification_release_dying(shell: :diagnostics)
      rescue StandardError => e
        warn "scheduler diagnostic INCOMPLETE: #{e.message}"
      end
    end
  end
end

def qualification_capture_dying(shell: nil)
  trace = machine.succeeds("cat #{QUAL_DYING_TRACE}/trace", timeout: 10, shell: shell)[1]
  puts "scheduler dying diagnostic trace:\n#{trace}"
  raise 'recording-off acknowledgement unavailable' unless @qualification_dying[:recording] == :off

  rows = qualification_dying_records(trace)
  stats = machine.succeeds("cat #{QUAL_DYING_TRACE}/per_cpu/cpu127/stats", timeout: 10, shell: shell)[1]
  puts "scheduler dying diagnostic buffer:\n#{stats}"
  losses = stats.scan(/^(?:commit overrun|overrun|dropped events):\s*(\d+)\s*$/).flatten
  raise 'missing or lossy dying buffer statistics' unless losses.length == 3 && losses.all? { |value| Integer(value) == 0 }

  profile = machine.succeeds(
    "awk '$1 ~ /scheduler_dying$/ { print $2, $3 }' /sys/kernel/tracing/kprobe_profile", timeout: 10, shell: shell
  )[1].split
  puts "scheduler dying diagnostic hits/misses: #{profile.join(' ')}"
  return if profile.length == 2 && Integer(profile[0]) >= rows && Integer(profile[1]) == 0

  raise 'missing or missed dying probe observations'
end

def qualification_observe_dying
  return yield unless qualification_dying_selected?

  state = @qualification_dying
  unless state && state[:prepared] && state[:arm] == :armed && state[:recording] == :off
    raise 'scheduler diagnostic INCOMPLETE: early preparation not acknowledged'
  end

  begin
    state[:recording] = :possible
    machine.succeeds("echo 1 > #{QUAL_DYING_TRACE}/tracing_on", timeout: 10)
    machine.succeeds("test \"$(cat #{QUAL_DYING_TRACE}/tracing_on)\" = 1", timeout: 10)
    state[:recording] = :on
    yield
  ensure
    original_error = $!
    shell = original_error ? :diagnostics : nil
    failures = []
    begin
      state[:recording] = :possible
      machine.succeeds("echo 0 > #{QUAL_DYING_TRACE}/tracing_on", timeout: 10, shell: shell)
      machine.succeeds("test \"$(cat #{QUAL_DYING_TRACE}/tracing_on)\" = 0", timeout: 10, shell: shell)
      state[:recording] = :off
    rescue StandardError => e
      failures << e.message
    end
    begin
      qualification_capture_dying(shell: shell)
    rescue StandardError => e
      failures << e.message
    end
    unless failures.empty?
      message = "scheduler diagnostic INCOMPLETE: #{failures.join('; ')}"
      warn message
      raise message unless original_error
    end
  end
end

def qualification_dying_drained?(shell: nil)
  return true unless @qualification_workload_started
  return true if @qualification_workload_drained

  # One read-only check, not a new drain wait or a stop request. These are
  # the existing successful population and stop_stress postconditions.
  command = %w[exit sctp.exit tun.exit].map { |file| "test \"$(cat #{QUAL_STATE}/#{file})\" = 0" } + [
    "grep -qx 'state=stopped' #{QUAL_STATE}/population",
    "grep -qx 'tasks=1' #{QUAL_STATE}/population",
    "test -e #{STRESS_STATE}/stop", "test ! -e #{STRESS_STATE}/pid"
  ]
  status, = machine.execute(command.join(' && '), timeout: 10, shell: shell)
  @qualification_workload_drained = status == 0
end

def qualification_release_dying(shell: nil)
  state = @qualification_dying
  return unless state
  return if state[:released]

  if state[:instance] == :none && state[:event] == :none
    state[:released] = true
    return
  end
  raise 'scheduler diagnostic INCOMPLETE: observer release already attempted; effects remain unconfirmed' if state[:release_attempted]

  state[:release_attempted] = true
  unless qualification_dying_drained?(shell: shell)
    raise 'scheduler diagnostic INCOMPLETE: workload drain unconfirmed; observer retained for VM teardown'
  end
  if state[:instance] == :possible || state[:event] == :possible || state[:arm] == :possible || state[:recording] != :off
    raise 'scheduler diagnostic INCOMPLETE: mutation effects unconfirmed; no destructive operation attempted'
  end

  event = "#{QUAL_DYING_TRACE}/events/lp95_dying/scheduler_dying"
  if state[:arm] == :armed
    state[:arm] = :possible
    machine.succeeds("echo 0 > #{event}/enable", timeout: 10, shell: shell)
    machine.succeeds("test \"$(cat #{event}/enable)\" = 0", timeout: 10, shell: shell)
    state[:arm] = :disarmed
  end
  if state[:event] == :owned
    state[:event] = :possible
    machine.succeeds("echo '-:lp95_dying/scheduler_dying' >> /sys/kernel/tracing/kprobe_events", timeout: 10, shell: shell)
    machine.succeeds('test ! -e /sys/kernel/tracing/events/lp95_dying/scheduler_dying', timeout: 10, shell: shell)
    state[:event] = :none
  end
  if state[:instance] == :owned
    state[:instance] = :possible
    machine.succeeds("rmdir #{QUAL_DYING_TRACE}", timeout: 10, shell: shell)
    machine.succeeds("test ! -e #{QUAL_DYING_TRACE}", timeout: 10, shell: shell)
    state[:instance] = :none
  end
  state[:released] = true
  puts 'scheduler dying observer released; workload drained or never started'
end

# This private instance uses existing tracepoints, never a new kernel probe.
QUAL_LOADER_TRACE = '/sys/kernel/tracing/instances/livepatch_qualification_loader'.freeze
QUAL_LOADER_EVENTS = {
  'csd/csd_queue_cpu' => %w[cpu callsite func csd],
  'csd/csd_function_entry' => %w[func csd],
  'csd/csd_function_exit' => %w[func csd],
  'ipi/ipi_send_cpu' => %w[cpu callsite callback],
  'ipi/ipi_send_cpumask' => %w[cpumask callsite callback]
}.freeze
QUAL_LOADER_RAW_LIMIT = 64 * 1024 * 1024
QUAL_LOADER_COMPRESSED_LIMIT = 2 * 1024 * 1024
QUAL_LOADER_METADATA_LIMIT = 128 * 1024

def qualification_loader_selected?
  qualification_dying_selected? && QUALIFICATION_AGE_SECONDS == 300
end

def qualification_loader_mapping(cpuinfo, ready)
  # Linux proc.c labels logical processor and APIC identity separately. QEMU
  # 10.2.4 x86-common.c assigns cpu_index from the APIC slot; the fixed topology
  # gives APIC slots 0..127. Never infer guest logical CPU == QEMU CPU index.
  guests = cpuinfo.split(/\n\s*\n/).map do |block|
    fields = block.lines.filter_map do |line|
      key, value = line.split(':', 2).map(&:strip)
      [key, value] if %w[processor apicid].include?(key) || ['initial apicid', 'physical id', 'core id', 'cpu cores', 'siblings'].include?(key)
    end
    raise 'duplicate guest CPU identity fields' unless fields.map(&:first).uniq.length == fields.length

    fields.to_h.transform_values { |value| Integer(value, 10) }
  end
  raise 'missing guest logical/APIC identities' unless guests.length == 128 &&
                                                       guests.map { |g| g.fetch('processor') }.sort == (0...128).to_a &&
                                                       guests.map { |g| g.fetch('apicid') }.sort == (0...128).to_a

  header, *threads = ready.lines.map(&:split)
  unless header&.length == 4 && header[0] == 'qemu' && header[1..2].all? { |v| /\A[1-9][0-9]*\z/.match?(v) } &&
         header[3] == '/nix/store/kanckc6ljipqzjsrvj4aqaf87a4rhswr-qemu-host-cpu-only-for-vm-tests-10.2.4/bin/qemu-system-x86_64'
    raise 'missing bound host QEMU identity'
  end
  raise 'missing host vCPU identities' unless threads.length == 128 && threads.all? do |row|
    row.length == 4 && row[0] == 'vcpu' && row[1..3].all? { |value| /\A[0-9]+\z/.match?(value) }
  end

  indices = threads.to_h { |_, index, tid, start| [Integer(index), [Integer(tid), Integer(start)]] }
  unless indices.keys.sort == (0...128).to_a && indices.values.map(&:first).uniq.length == 128 &&
         indices.values.flatten.all? { |value| value > 0 }
    raise 'ambiguous host vCPU identity'
  end

  guests.sort_by { |g| g.fetch('processor') }.map do |g|
    apic = g.fetch('apicid')
    unless g.fetch('initial apicid') == apic && g.fetch('physical id') == 0 && g.fetch('core id') == apic &&
           g.fetch('cpu cores') == 128 && g.fetch('siblings') == 128
      raise 'guest topology does not match frozen QEMU mapping'
    end

    tid, start = indices.fetch(apic)
    "guest_cpu=#{g.fetch('processor')} apic=#{apic} qemu_index=#{apic} tid=#{tid} start=#{start}"
  end
end

def qualification_loader_host_file(name)
  path = File.join(@qualification_loader.fetch(:host), name)
  raise "unsafe host evidence #{name}" unless File.file?(path) && !File.symlink?(path) && File.size(path) <= 65_536

  File.read(path, 65_537)
end

def qualification_prepare_loader
  return unless qualification_loader_selected?
  raise 'loader diagnostic already prepared or uncertain' if @qualification_loader

  state = @qualification_loader = {
    host: File.join(ENV.fetch('TEST_RUNNER_STATE_DIR'), 'loader-host'), instance: :none,
    pending: false, enabled: [], recording: :unknown, prepared: false, released: false, release_attempted: false
  }
  begin
    machine.succeeds('test "$(uname -r)" = 6.12.95.5', timeout: 10)
    machine.succeeds(
      'test "$(sha256sum /sys/kernel/notes | cut -d\' \' -f1)" = ' \
      '1e4432629c0f1a1e9c6b175495217859279f98ded2beca091834ec059e42108a', timeout: 10
    )
    raise 'host evidence directory missing or symlinked' unless File.directory?(state[:host]) && !File.symlink?(state[:host])

    machine.succeeds('for tool in bash head gzip base64; do command -v "$tool" >/dev/null || exit; done', timeout: 10, shell: :diagnostics)
    probe = machine.succeeds("printf %s loader-codec-probe | #{qualification_loader_export_command('/dev/stdin')}", timeout: 10, shell: :diagnostics)[1]
    raise 'loader codec round trip unavailable' unless qualification_loader_decode(probe).first == 'loader-codec-probe'

    state[:handshake_send] = [Time.now.to_f, Process.clock_gettime(Process::CLOCK_MONOTONIC)]
    File.write(File.join(state[:host], 'request.txt'), "guest ready wall=#{state[:handshake_send][0]}\n", mode: 'wx')
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    until File.file?(File.join(state[:host], 'ready.txt'))
      if File.file?(File.join(state[:host], 'status.txt'))
        status = qualification_loader_host_file('status.txt')
        raise status if status.start_with?('INCOMPLETE:')
      end
      raise 'host readiness acknowledgement unavailable' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.1
    end
    ready = qualification_loader_host_file('ready.txt')
    state[:handshake_reply] = [Time.now.to_f, Process.clock_gettime(Process::CLOCK_MONOTONIC)]
    qualification_loader_bracket('host-request-ready', state[:handshake_send], state[:handshake_reply])
    puts 'loader host baseline: required_vcpu_threads=128 cpu_units=proc_stat_ticks CLK_TCK=UNAVAILABLE; switches supplemental; runtime/wait/slices=UNAVAILABLE; no runnable-wait or starvation inference'
    info = machine.succeeds('cat /proc/cpuinfo', timeout: 10)[1]
    mapping = qualification_loader_mapping(info, ready)
    puts "loader host ready:\n#{ready}loader guest mapping:\n#{mapping.join("\n")}"
    File.write(File.join(state[:host], 'guest-map.txt'), "#{mapping.join("\n")}\n", mode: 'wx')
    raise 'host sampler not sampling' unless qualification_loader_host_file('status.txt').strip == 'sampling'

    funcs = %w[do_flush_tlb_all do_kernel_range_flush].map { |name| symbol_address(machine, name) }
    callback = symbol_address(machine, 'generic_smp_call_function_single_interrupt')
    state[:symbols] = %w[do_flush_tlb_all do_kernel_range_flush generic_smp_call_function_single_interrupt].zip(funcs + [callback]).to_h
    state[:filters] = {}
    machine.succeeds("test ! -e #{QUAL_LOADER_TRACE}", timeout: 10)
    state[:instance] = :possible
    machine.succeeds("mkdir #{QUAL_LOADER_TRACE}", timeout: 10)
    state[:instance] = :owned
    machine.succeeds("test \"$(cat #{QUAL_LOADER_TRACE}/current_tracer)\" = nop", timeout: 10)
    machine.succeeds("echo 0 > #{QUAL_LOADER_TRACE}/tracing_on && test \"$(cat #{QUAL_LOADER_TRACE}/tracing_on)\" = 0", timeout: 10)
    state[:recording] = :off
    ["echo global > #{QUAL_LOADER_TRACE}/trace_clock", "echo 64 > #{QUAL_LOADER_TRACE}/buffer_size_kb",
     "echo 0 > #{QUAL_LOADER_TRACE}/options/overwrite", "echo ffffffff,ffffffff,ffffffff,ffffffff > #{QUAL_LOADER_TRACE}/tracing_cpumask",
     "echo > #{QUAL_LOADER_TRACE}/trace"].each { |command| machine.succeeds(command, timeout: 10) }
    QUAL_LOADER_EVENTS.each do |name, fields|
      event = "#{QUAL_LOADER_TRACE}/events/#{name}"
      format = machine.succeeds("cat #{event}/format", timeout: 10)[1]
      fields.each { |field| raise "unsupported #{name} field #{field}" unless /field:[^;]*\b#{field};/.match?(format) }
      filter = name.start_with?('csd/') ? funcs.map { |address| "func == #{address}" }.join(' || ') : "callback == #{callback}"
      machine.succeeds("echo #{Shellwords.escape(filter)} > #{event}/filter", timeout: 10)
      raise "filter readback mismatch #{name}" unless machine.succeeds("cat #{event}/filter", timeout: 10)[1].strip == filter

      state[:filters][name] = filter
      state[:pending] = true
      machine.succeeds("echo 1 > #{event}/enable && test \"$(cat #{event}/enable)\" = 1", timeout: 10)
      state[:enabled] << name
      state[:pending] = false
    end
    machine.succeeds("test \"$(cat #{QUAL_LOADER_TRACE}/tracing_on)\" = 0 && " \
                     "test \"$(cat #{QUAL_LOADER_TRACE}/current_tracer)\" = nop", timeout: 10)
    state[:prepared] = true
    puts 'loader diagnostic prepared global nop OFF; five filtered native events enabled before workload'
  ensure
    unless state[:prepared]
      puts "loader host handshake send=#{state[:handshake_send].inspect} reply=#{state[:handshake_reply].inspect}; missing relation=UNAVAILABLE" unless state[:handshake_reply]
      warn 'loader diagnostic INCOMPLETE: early preparation failed'
      begin
        qualification_release_loader(drained: !@qualification_workload_started, shell: :diagnostics)
      rescue StandardError => e
        warn "loader diagnostic INCOMPLETE: #{e.message}"
      end
    end
  end
end

# These are labelled command intervals, never a cross-clock point conversion.
def qualification_loader_bracket(label, sent, received, guest: nil)
  valid = [sent, received].all? do |pair|
    pair.is_a?(Array) && pair.length == 2 && pair.all? { |v| v.is_a?(Numeric) && v.to_f.finite? }
  end
  valid &&= received[0] >= sent[0] && received[1] >= sent[1]
  relation = valid ? 'interval_only' : 'UNAVAILABLE'
  puts "loader bracket label=#{label} clock_views=runner-EPOCHREALTIME/runner-CLOCK_MONOTONIC send=#{sent.inspect} reply=#{received.inspect} guest_view=guest-uptime/trace-global guest=#{guest.inspect}; relation=#{relation} forward_wall_changes=uncalibrated"
  raise 'loader clock relation UNAVAILABLE: missing, invalid or regressing command bracket' unless valid
end

def qualification_loader_clock(label, shell: nil)
  before = [Time.now.to_f, Process.clock_gettime(Process::CLOCK_MONOTONIC)]
  body = "printf 'loader clock=#{label} uptime=%s\\n' \"$up\""
  output = machine.succeeds("read up idle < /proc/uptime && #{body} > #{QUAL_LOADER_TRACE}/trace_marker && #{body}", timeout: 10, shell: shell)[1]
  raise 'missing guest clock bracket' unless /\Aloader clock=#{Regexp.escape(label)} uptime=[0-9]+\.[0-9]+\n\z/.match?(output)

  qualification_loader_bracket(label, before, [Time.now.to_f, Process.clock_gettime(Process::CLOCK_MONOTONIC)], guest: output.strip)
end

def qualification_loader_command(attempt)
  return "LC_ALL=C insmod #{CORRECTED_MODULE} 2>&1" unless @qualification_loader

  script = 'set -C; read up idle < /proc/uptime; ' \
           "printf 'loader attempt=#{attempt} pid=%s uptime=%s\\n' \"$$\" \"$up\" > #{QUAL_STATE}/loader-attempt-#{attempt}; " \
           "cat #{QUAL_STATE}/loader-attempt-#{attempt} >| #{QUAL_LOADER_TRACE}/trace_marker; " \
           "export LC_ALL=C; exec insmod #{CORRECTED_MODULE} 2>&1"
  "sh -ec #{Shellwords.escape(script)}"
end

def qualification_freeze_loader
  state = @qualification_loader
  return if state[:freeze_attempted]

  state[:freeze_attempted] = true
  state[:recording] = :possible
  sent = [Time.now.to_f, Process.clock_gettime(Process::CLOCK_MONOTONIC)]
  output = machine.succeeds(
    "echo 0 > #{QUAL_LOADER_TRACE}/tracing_on && test \"$(cat #{QUAL_LOADER_TRACE}/tracing_on)\" = 0 && " \
    "read up idle < /proc/uptime && printf 'loader frozen uptime=%s\\n' \"$up\"", timeout: 10, shell: :diagnostics
  )[1]
  state[:recording] = :off
  raise 'missing frozen guest clock' unless /\Aloader frozen uptime=[0-9]+\.[0-9]+\n\z/.match?(output)

  qualification_loader_bracket('freeze', sent, [Time.now.to_f, Process.clock_gettime(Process::CLOCK_MONOTONIC)], guest: output.strip)
end

def qualification_stop_loader_observer
  state = @qualification_loader
  return unless state && state[:observer]

  state[:stop] = true
  state[:observer].join
  state[:observer] = nil
end

def qualification_loader_records(trace)
  raise 'missing window clock marker' unless /tracing_mark_write: loader clock=begin uptime=[0-9.]+/.match?(trace)
  raise 'missing activation marker' unless /tracing_mark_write: loader attempt=1 pid=[1-9][0-9]* uptime=[0-9.]+/.match?(trace)
  raise 'trace reports lost events' if /LOST.*EVENT|buffer full/i.match?(trace)

  counts = Hash.new(0)
  pending = {}
  unknown = 0
  attempt = nil
  trace.each_line do |line|
    if (marker = /tracing_mark_write: loader attempt=(\d+) pid=(\d+) uptime=[0-9.]+/.match(line))
      attempt = marker.captures.map { |value| Integer(value) }
    end
    match = /-(\d+)\s+\[(\d+)\].*?\s(\d+\.\d+): (csd_queue_cpu|csd_function_entry|csd_function_exit|ipi_send_cpu|ipi_send_cpumask): (.*)/.match(line)
    unless match
      raise 'unsupported loader event header' if /(?:csd_queue_cpu|csd_function_entry|csd_function_exit|ipi_send_cpu|ipi_send_cpumask):/.match?(line)

      next
    end

    pid, cpu, time, event, body = match.captures
    raise 'invalid loader event header' unless Integer(cpu) < 128 && Integer(pid) >= 0 && Float(time) >= 0

    if event.start_with?('csd_')
      raise 'unbound CSD callback/token' unless /func=(?:do_flush_tlb_all|do_kernel_range_flush),? csd=\s*(?:[0-9a-f]{16}|\(null\))\s*$/.match?(body)

      func = body[/func=([^, ]+)/, 1]
      token = body[/csd=\s*(\S+)/, 1]
      if event == 'csd_queue_cpu'
        target = /\Acpu=(\d+) callsite=\S+ func=/.match(body)
        raise 'missing CSD queue target/callsite' unless target && Integer(target[1]) < 128

        key = [func, token, Integer(target[1])]
        raise 'overlapping CSD token reuse; history incomplete' if pending.has_key?(key)

        pending[key] = { entered: false, attempt: attempt && attempt[1] == Integer(pid) ? attempt[0] : nil }
      elsif %w[0000000000000000 (null)].include?(token)
        counts['local_null'] += 1
      else
        key = [func, token, Integer(cpu)]
        operation = pending[key]
        if event == 'csd_function_entry' && operation && !operation[:entered]
          operation[:entered] = true
        elsif event == 'csd_function_exit' && operation && operation[:entered]
          pending.delete(key)
          counts['completed'] += 1
        else
          unknown += 1
        end
      end
    else
      raise 'missing IPI dispatch identity' unless /\A(?:cpu=\d+|cpumask=[0-9a-f,]+) callsite=\S+ callback=generic_smp_call_function_single_interrupt(?:\+\S+)?\s*$/.match?(body)
    end
    counts[event] += 1
  end
  raise 'no bound CSD progress records' if counts.values.sum == 0 || counts.keys.none? { |name| name.start_with?('csd_') }

  puts "loader CSD at freeze queued_without_entry=#{pending.values.count { |v| !v[:entered] }} entered_without_exit=#{pending.values.count { |v| v[:entered] }} unassociated_origin=#{pending.values.count { |v| v[:attempt].nil? }} unknown_prior_history=#{unknown}"
  counts
end

# One framed, bounded export through the ordinary diagnostic shell. A footer
# is written only after every pipeline stage succeeds; caps are not EOF.
def qualification_loader_export_command(path)
  script = "printf 'LP95_GZIP_BEGIN\\n'; head -c #{QUAL_LOADER_RAW_LIMIT + 1} #{Shellwords.escape(path)} | " \
           "gzip -1 -c | head -c #{QUAL_LOADER_COMPRESSED_LIMIT + 1} | base64 -w0; printf '\\nLP95_GZIP_END\\n'"
  "bash -e -o pipefail -c #{Shellwords.escape(script)}"
end

def qualification_loader_decode(output)
  encoded_limit = 4 * ((QUAL_LOADER_COMPRESSED_LIMIT + 3) / 3)
  prefix = "LP95_GZIP_BEGIN\n"
  suffix = "\nLP95_GZIP_END\n"
  raise 'loader encoded payload cap exceeded' if output.bytesize > encoded_limit + prefix.bytesize + suffix.bytesize
  raise 'loader payload framing unavailable' unless output.start_with?(prefix) && output.end_with?(suffix)

  compressed = Base64.strict_decode64(output.byteslice(prefix.bytesize, output.bytesize - prefix.bytesize - suffix.bytesize))
  raise 'loader compressed payload cap exceeded' if compressed.bytesize > QUAL_LOADER_COMPRESSED_LIMIT

  input = StringIO.new(compressed)
  reader = Zlib::GzipReader.new(input)
  native = +''.b
  loop do
    chunk = reader.read([65_536, QUAL_LOADER_RAW_LIMIT + 1 - native.bytesize].min)
    break if chunk.nil? || chunk.empty?

    native << chunk
    raise 'loader decoded payload cap exceeded' if native.bytesize > QUAL_LOADER_RAW_LIMIT
  end
  raise 'loader gzip stream incomplete or has trailing data' unless reader.eof? && reader.unused.to_s.empty? && input.eof?

  reader.finish
  [native, compressed.bytesize]
ensure
  reader.close if reader && !reader.closed?
end

def qualification_loader_attempt_rows(attempts)
  rows = attempts.lines.map do |line|
    match = /\Aloader attempt=([1-9][0-9]*) pid=([1-9][0-9]*) uptime=([0-9]+\.[0-9]+)\n\z/.match(line)
    raise 'malformed actual attempt PID file' unless match

    match.captures
  end
  raise 'missing actual attempt PID files' unless rows.map { |row| Integer(row[0]) }.sort == (1..rows.length).to_a && !rows.empty?

  rows
end

def qualification_loader_buffer_stats(stats)
  blocks = stats.split(/^CPU=/).drop(1)
  raise 'missing CPU buffer statistics' unless blocks.map { |block| Integer(block.lines.first, 10) }.sort == (0...128).to_a

  blocks.each do |block|
    losses = block.scan(/^(?:commit overrun|overrun|dropped events):\s*(\d+)\s*$/).flatten
    bytes = block[/^bytes:\s*(\d+)\s*$/, 1]
    raise 'lossy, saturated or missing loader statistics' unless losses.length == 3 && losses.all? { |v| Integer(v) == 0 } && bytes && Integer(bytes) < 65_536
  end
end

def qualification_loader_metadata_items
  state = @qualification_loader
  identity = "printf 'kernel '; uname -r; printf 'system '; readlink -f /run/current-system; " \
             "printf 'notes '; sha256sum /sys/kernel/notes; printf 'module '; sha256sum #{CORRECTED_MODULE}; " \
             "printf 'sites '; sha256sum /etc/livepatch-test/sites.json"
  names = state.fetch(:symbols).keys.map { |name| "$3 == \"#{name}\"" }.join(' || ')
  callbacks = "awk '$2 !~ /^[Uu]$/ && NF == 3 && (#{names}) { print $3, \"0x\" $1 }' /proc/kallsyms"
  items = [['attempts', "cat #{QUAL_STATE}/loader-attempt-*", nil], ['identity', identity, nil], ['callbacks', callbacks, nil]]
  { 'tracing_on' => '0', 'current_tracer' => 'nop', 'trace_clock' => :global,
    'tracing_cpumask' => 'ffffffff,ffffffff,ffffffff,ffffffff', 'buffer_size_kb' => '64', 'options/overwrite' => '0' }.each do |name, expected|
    items << [name, "cat #{QUAL_LOADER_TRACE}/#{name}", expected]
  end
  QUAL_LOADER_EVENTS.each_key do |name|
    items << ["#{name}/enable", "cat #{QUAL_LOADER_TRACE}/events/#{name}/enable", '1']
    items << ["#{name}/filter", "cat #{QUAL_LOADER_TRACE}/events/#{name}/filter", state.fetch(:filters).fetch(name)]
  end
  # Missing one CPU remains explicit while independent CPU blocks are retained.
  items << ['buffers', "for cpu in $(seq 0 127); do echo CPU=$cpu; cat #{QUAL_LOADER_TRACE}/per_cpu/cpu$cpu/stats || echo UNAVAILABLE; done", nil]
  items
end

def qualification_loader_validate_metadata(name, output, expected)
  case name
  when 'attempts'
    qualification_loader_attempt_rows(output)
  when 'identity'
    lines = output.lines.map(&:split)
    raise 'loader kernel/source/notes/module/sites identity unavailable' unless lines.length == 5 &&
                                                                                lines[0].length == 2 && /\A6\.12\.95\.[57]\z/.match?(lines[0][1]) &&
                                                                                lines[0][0] == 'kernel' && lines[1].length == 2 && lines[1][0] == 'system' && lines[1][1].start_with?('/nix/store/') &&
                                                                                lines[2] == ['notes', '1e4432629c0f1a1e9c6b175495217859279f98ded2beca091834ec059e42108a', '/sys/kernel/notes'] &&
                                                                                lines[3] == ['module', CORRECTED_SHA256, CORRECTED_MODULE] &&
                                                                                lines[4] == ['sites', SITES_SHA256, '/etc/livepatch-test/sites.json']
  when 'callbacks'
    rows = output.lines.map(&:split)
    raise 'loader callback identities changed or ambiguous' unless rows.length == 3 && rows.all? { |row| row.length == 2 } && rows.to_h == @qualification_loader.fetch(:symbols)
  when 'buffers'
    qualification_loader_buffer_stats(output)
  else
    valid = expected == :global ? output.split.include?('[global]') : output.strip == expected
    raise "loader #{name} readback mismatch" unless valid
  end
end

def qualification_capture_loader(prior_errors: [])
  state = @qualification_loader
  errors = []
  data = {}
  directory = state.fetch(:host)
  metadata_path = File.join(directory, 'metadata.txt')
  native_path = File.join(directory, 'native.log')
  native = compressed_size = nil
  raise 'loader evidence directory missing or symlinked' unless File.directory?(directory) && !File.symlink?(directory)

  # Flush every bounded item before attempting the large transport. Neither an
  # item failure nor a later payload failure erases earlier evidence.
  File.open(metadata_path, 'wx') do |file|
    file.write("recording=#{state[:recording]} first_fault=#{state[:fault].to_s.byteslice(0, 512).inspect} prior_errors=#{prior_errors.map { |e| e.byteslice(0, 512) }.inspect}\n")
    qualification_loader_metadata_items.each do |name, command, expected|
      script = "{ #{command}; } | head -c #{QUAL_LOADER_METADATA_LIMIT + 1}"
      output = machine.succeeds("bash -e -o pipefail -c #{Shellwords.escape(script)}", timeout: 10, shell: :diagnostics)[1]
      entry = "\n=== #{name} ===\n#{output}\n"
      # Reserve bounded space for unavailable-item records, within 128 KiB.
      raise '128KiB loader metadata cap exceeded' if file.pos + entry.bytesize > QUAL_LOADER_METADATA_LIMIT - 16_384

      file.write(entry)
      file.flush
      data[name] = output
      qualification_loader_validate_metadata(name, output, expected)
    rescue StandardError => e
      error = "#{name}: #{e.class}: #{e.message}".byteslice(0, 512)
      errors << error
      file.write("\n=== #{name} UNAVAILABLE ===\n#{error}\n")
      file.flush
    end
  end
  errors << 'loader freeze not acknowledged' unless state[:recording] == :off
  errors << state[:observer_error] if state[:observer_error]
  begin
    output = machine.succeeds(qualification_loader_export_command("#{QUAL_LOADER_TRACE}/trace"), timeout: 10, shell: :diagnostics)[1]
    native, compressed_size = qualification_loader_decode(output)
    File.write(native_path, native, mode: 'wx')
    if errors.empty? && prior_errors.empty?
      attempt_rows = qualification_loader_attempt_rows(data.fetch('attempts'))
      markers = native.scan(/tracing_mark_write: loader attempt=(\d+) pid=(\d+) uptime=([0-9.]+)/)
      raise 'attempt file/trace PID disagreement' unless markers.all? { |row| attempt_rows.include?(row) }

      counts = qualification_loader_records(native)
      puts "loader records #{counts.inspect}; tokens may be reused; queue is not dispatch/delivery; local CSD may be NULL; target PID is interrupted context"
    end
  rescue StandardError => e
    errors << "native: #{e.class}: #{e.message.byteslice(0, 512)}"
  end
  begin
    host_status = qualification_loader_host_file('status.txt').strip
    raise "host sampler coverage incomplete: #{host_status}" unless host_status == 'sampling'
  rescue StandardError => e
    errors << e.message.byteslice(0, 512)
  end
  status = errors.empty? && prior_errors.empty? ? 'COMPLETE' : 'INCOMPLETE'
  File.write(File.join(directory, 'native-status.txt'),
             "#{status} transport=#{native ? 'complete' : 'incomplete'} compressed_bytes=#{compressed_size || 'UNAVAILABLE'} " \
             "native_bytes=#{native&.bytesize || 'UNAVAILABLE'} sha256=#{native ? Digest::SHA256.hexdigest(native) : 'UNAVAILABLE'}\n" \
             "#{(prior_errors + errors).join("\n")}\n", mode: 'wx')
  puts "loader native #{status}: #{native_path}; metadata=#{metadata_path}; compressed_bytes=#{compressed_size || 'UNAVAILABLE'} native_bytes=#{native&.bytesize || 'UNAVAILABLE'}"
  raise errors.join('; ') unless errors.empty?
end

def qualification_observe_loader
  return yield unless @qualification_loader

  state = @qualification_loader
  raise 'loader early preparation unacknowledged' unless state[:prepared]

  begin
    cursor = machine.console_output.bytesize
    state[:recording] = :possible
    machine.succeeds("echo 1 > #{QUAL_LOADER_TRACE}/tracing_on && test \"$(cat #{QUAL_LOADER_TRACE}/tracing_on)\" = 1", timeout: 10)
    state[:recording] = :on
    qualification_loader_clock('begin')
    state[:stop] = false
    state[:observer] = Thread.new do
      loop do
        text = machine.console_output.b
        fresh = text.byteslice(cursor..).to_s
        if (fault = fresh[/[^\n]*watchdog: BUG: soft lockup[^\n]*/])
          state[:fault] = fault
          puts "loader first softlockup observed wall=#{Time.now.to_f} mono=#{Process.clock_gettime(Process::CLOCK_MONOTONIC)} line=#{fault.inspect}"
          qualification_freeze_loader
          break
        end
        newline = fresh.rindex("\n")
        cursor += newline + 1 if newline
        break if state[:stop]

        sleep 0.25
      end
    rescue StandardError => e
      state[:observer_error] = e.message
    end
    yield
  ensure
    qualification_finish_loader
  end
end

def qualification_finish_loader
  state = @qualification_loader
  return unless state && !state[:finished]

  state[:finished] = true
  original = $!
  failures = []
  [-> { qualification_stop_loader_observer },
   -> { qualification_loader_clock('end', shell: :diagnostics) unless state[:freeze_attempted] },
   -> { qualification_freeze_loader },
   -> { qualification_capture_loader(prior_errors: failures) },
   -> { File.write(File.join(state[:host], 'window-complete.txt'), "window closed wall=#{Time.now.to_f} recording=#{state[:recording]}\n") }].each do |step|
    step.call
  rescue StandardError => e
    failures << e.message
  end
  return if failures.empty?

  message = "loader diagnostic INCOMPLETE: #{failures.join('; ')}"
  warn message
  raise message unless original
end

def qualification_release_loader(drained:, shell: nil)
  state = @qualification_loader
  return unless state && !state[:released]
  return if state[:instance] == :none

  raise 'loader release already attempted' if state[:release_attempted]

  state[:release_attempted] = true
  raise 'loader workload drain unconfirmed; retained for VM teardown' unless drained
  raise 'loader effects unconfirmed; no destructive operation' unless state[:instance] == :owned && !state[:pending] && state[:recording] == :off

  state[:enabled].reverse_each do |name|
    state[:pending] = true
    machine.succeeds("echo 0 > #{QUAL_LOADER_TRACE}/events/#{name}/enable && test \"$(cat #{QUAL_LOADER_TRACE}/events/#{name}/enable)\" = 0", timeout: 10, shell: shell)
    state[:pending] = false
  end
  state[:instance] = :possible
  machine.succeeds("rmdir #{QUAL_LOADER_TRACE} && test ! -e #{QUAL_LOADER_TRACE}", timeout: 10, shell: shell)
  state[:released] = true
  puts 'loader observer released after confirmed drain or before workload'
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
  qualification_observe_loader { qualification_activate_attempts(previous_name) }
end

def qualification_activate_attempts(previous_name)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  deadline = started + QUALIFICATION_TRANSITION_SECONDS
  attempts = 0
  loop do
    remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
    raise 'qualification activation deadline expired' unless remaining > 0

    attempts += 1
    begin
      sent = [Time.now.to_f, Process.clock_gettime(Process::CLOCK_MONOTONIC)]
      status, output = machine.execute(qualification_loader_command(attempts), timeout: remaining)
      qualification_loader_bracket("attempt=#{attempts}", sent, [Time.now.to_f, Process.clock_gettime(Process::CLOCK_MONOTONIC)]) if @qualification_loader
    rescue StandardError => e
      # Activation can time out before wait_for_patch is reached. Use its
      # existing bounded reporter before the after-hook releases the workload.
      puts "loader attempt=#{attempts} reply=UNAVAILABLE send=#{sent.inspect} error_observed=#{[Time.now.to_f, Process.clock_gettime(Process::CLOCK_MONOTONIC)].inspect}; command may remain active" if @qualification_loader
      qualification_finish_loader
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
      # The final wait combines three exit markers. Report each marker and
      # workload log so a teardown timeout identifies the unfinished workload.
      if @qualification_dying && @qualification_dying[:instance] == :owned
        puts "scheduler dying pre-cleanup ownership: #{@qualification_dying.inspect}"
        begin
          machine.execute(
            "cat #{QUAL_DYING_TRACE}/tracing_on #{QUAL_DYING_TRACE}/trace " \
            "#{QUAL_DYING_TRACE}/per_cpu/cpu127/stats /sys/kernel/tracing/kprobe_profile",
            timeout: 10, shell: :diagnostics
          )
        rescue StandardError => e
          warn "scheduler dying pre-cleanup snapshot unavailable: #{e.message}"
        end
      end
      commands = [
        "ls -l #{QUAL_STATE}; " \
        'for name in population.log sctp.log tun.log exit sctp.exit tun.exit; do ' \
        "state_file=#{QUAL_STATE}/$name; " \
        'printf "\n=== %s ===\n" "$state_file"; tail -n 200 "$state_file" 2>&1 || true; done; ' \
        "population_pid=$(sed -n 's/^pid=//p' #{QUAL_STATE}/population); " \
        'case "$population_pid" in ""|*[!0-9]*) echo "population controller PID unavailable";; *) ' \
        'if test "$(timeout -k 1 2 cat /proc/"$population_pid"/comm 2>/dev/null)" = task-population; then ' \
        'snapshot_count=0; ' \
        'for snapshot_pid in "$population_pid" ' \
        '$(timeout -k 1 2 cat /proc/"$population_pid"/task/"$population_pid"/children 2>/dev/null); do ' \
        'case "$snapshot_pid" in ""|*[!0-9]*) continue;; esac; ' \
        'for name in status stat wchan syscall stack; do state_file=/proc/$snapshot_pid/$name; ' \
        'printf "\n=== population process %s ===\n" "$state_file"; ' \
        'timeout -k 1 2 cat "$state_file" 2>&1 || true; done; ' \
        'snapshot_count=$((snapshot_count + 1)); test "$snapshot_count" -lt 2 || break; done; ' \
        'else echo "population controller no longer present pid=$population_pid"; fi; esac; ' \
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
ensure
  if @qualification_dying && !@qualification_dying[:released] && !@qualification_completed
    begin
      if machine.running?
        qualification_release_dying(shell: :diagnostics)
      else
        warn 'scheduler diagnostic INCOMPLETE: guest unavailable for owned observer cleanup'
      end
    rescue StandardError => e
      warn "scheduler diagnostic INCOMPLETE: #{e.message}"
    end
  end
  begin
    qualification_release_loader(drained: !@qualification_workload_started || @qualification_workload_drained, shell: :diagnostics)
  rescue StandardError => e
    raise if @qualification_completed

    warn "loader diagnostic INCOMPLETE: #{e.message}"
  end
end

it 'qualifies the exact predecessor at the declared task, CPU, age and memory envelope' do
  @qualification_completed = false
  @qualification_dying = nil
  @qualification_loader = nil
  @qualification_workload_started = false
  @qualification_workload_drained = false
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
  qualification_prepare_dying
  qualification_prepare_loader

  @qualification_workload_started = true
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
    # A newer published snapshot can still precede worker wakeups.
    qualification_wait_for_progress(population)
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
  qualification_observe_dying { qualification_hotplug(phase: 'pre-transition') }
  qualification_failed_activation(previous_name) if QUALIFICATION_FAILURE_RETENTION
  qualification_trace_start
  before = qualification_population
  counts = stress_counts(machine)
  qualification_activate(previous_name)
  wait_for_patch(machine, previous_name, 0)
  machine.fails("test -d /sys/module/#{forbidden_name}")
  machine.succeeds("rmmod #{previous_name}")
  qualification_trace_counts(disabled: false)
  qualification_hotplug(phase: 'post-transition')
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
  @qualification_workload_drained = true
  qualification_release_dying
  qualification_release_loader(drained: true)
  consume_transition_state(machine)
  machine.succeeds('ip link del klp_qual_tap')
  groups.each { |group| machine.succeeds("rmdir #{group}") }
  assert_kernel_healthy(machine, @example_dmesg_start)
  qualification_shutdown_diagnostics
  @qualification_completed = true
end
