# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'open3'
require 'shellwords'
require 'tmpdir'

RSpec.describe TestRunner::ExampleGroup, '#evaluate' do
  let(:machine) { instance_spy(OsVm::Machine, running?: true, execute: [0, '']) }
  let(:group) { described_class.new('qualification', config: TestRunner::ExampleConfiguration.new) }
  let(:primary_error) { RuntimeError.new('original migration failure') }
  let(:cleanup_error) { OsVm::UnrecoverableTimeoutError.new('diagnostic shell unavailable') }

  let(:context) do
    klass = Class.new do
      class << self
        attr_accessor :machine, :group

        def after(type, &block)
          group.add_after(type, block)
        end

        # Register only the real cleanup hook, not the VM workload example.
        def it(*); end
      end
    end
    klass.machine = machine
    klass.group = group
    klass.const_set(:STRESS_STATE, '/run/stress')
    klass.const_set(:QUALIFICATION_CPUS, 4)
    source = File.join(REPO_ROOT, 'tests/suite/kernel/livepatch-6.12.95/qualification.rb')
    klass.class_eval(File.read(source), source)
    klass
  end

  def add_failed_example
    context.instance_variable_set(:@qualification_completed, false)
    error = primary_error
    group.add_example(TestRunner::Example.new(group, 'migration') { raise error })
  end

  it 'retains the original exception when failure diagnostics time out' do
    add_failed_example
    allow(machine).to receive(:execute).and_raise(cleanup_error)

    results = nil
    expect { results = group.evaluate }.to output(/qualification failure diagnostics or cleanup unavailable.*diagnostic shell unavailable/).to_stderr
    expect(results.length).to eq(1)
    expect(results.first).to be_failure
    expect(results.first.exception).to equal(primary_error)
    expect(machine).to have_received(:execute).once
  end

  it 'retains the original exception when later cleanup times out' do
    add_failed_example
    allow(machine).to receive(:execute).with(
      a_string_including('cleanup_status'), timeout: 30, shell: :diagnostics
    ).and_raise(cleanup_error)

    results = nil
    expect { results = group.evaluate }.to output(/diagnostic shell unavailable/).to_stderr
    expect(results.first.exception).to equal(primary_error)
    expect(machine).to have_received(:execute).exactly(4).times
  end

  it 'still propagates cleanup failure after successful qualification' do
    context.instance_variable_set(:@qualification_completed, true)
    group.add_example(TestRunner::Example.new(group, 'completed') { nil })
    allow(machine).to receive(:execute).and_raise(cleanup_error)

    expect { group.evaluate }.to(raise_error { |error| expect(error).to equal(cleanup_error) })
  end

  it 'does not run guest commands after the VM has stopped' do
    add_failed_example
    allow(machine).to receive(:running?).and_return(false)

    expect(group.evaluate.first.exception).to equal(primary_error)
    expect(machine).not_to have_received(:execute)
  end

  it 'keeps ordinary failure diagnostics and cleanup when the guest responds' do
    add_failed_example

    expect(group.evaluate.first.exception).to equal(primary_error)
    expect(machine).to have_received(:execute).exactly(4).times
  end

  it 'captures qualification state on the reserved channel when the primary shell is occupied' do
    add_failed_example
    primary_shell_error = OsVm::UnrecoverableTimeoutError.new('primary shell still occupied')
    commands = []
    allow(machine).to receive(:execute) do |command, **options|
      raise primary_shell_error unless options[:shell] == :diagnostics

      commands << command
      [0, 'reserved snapshot']
    end

    results = nil
    expect { results = group.evaluate }.not_to output.to_stderr
    expect(results.first.exception).to equal(primary_error)
    expect(machine).to have_received(:execute).with(
      a_string_including('/trace', '*/enabled', '*/transition'),
      timeout: 30, shell: :diagnostics
    )
    expect(machine).to have_received(:execute).with(a_string_including('output.log', 'ipset'), timeout: 30, shell: :diagnostics)
    expect(machine).to have_received(:execute).with(a_string_including('dmesg'), timeout: 30, shell: :diagnostics)
    expect(machine).to have_received(:execute).with(
      a_string_including('cleanup_status', '/stop', '/sctp.release', '/tun.stop', '/cpu3/online'),
      timeout: 30, shell: :diagnostics
    )
    expect(commands.length).to eq(4)
    commands.each do |command|
      expect(command).to start_with('timeout -k 1 25 sh -c ')
      _stdout, stderr, status = Open3.capture3('sh', '-n', stdin_data: command)
      expect(status).to be_success, stderr
    end
  end

  it 'cleans trace events in reverse order inside the same failure-only bound' do
    add_failed_example
    context.instance_variable_set(:@qualification_events, %w[first second])
    commands = []
    allow(machine).to receive(:execute) do |command, **options|
      expect(options).to eq(timeout: 30, shell: :diagnostics)
      commands << Shellwords.split(command).last
      [0, '']
    end

    expect(group.evaluate.first.exception).to equal(primary_error)
    expect(commands.length).to eq(4)
    cleanup = commands.last
    expect(cleanup.index('/stop')).to be < cleanup.index('/cpu3/online')
    expect(cleanup.index('/second/enable')).to be < cleanup.index('/first/enable')
    expect(cleanup).to include("echo '-:lp95_qualification/second'", "echo '-:lp95_qualification/first'")
    expect(cleanup).to end_with('exit "$cleanup_status"')
  end

  it 'reports a bounded cleanup failure without replacing the original exception' do
    add_failed_example
    allow(machine).to receive(:execute).with(
      a_string_including('cleanup_status'), timeout: 30, shell: :diagnostics
    ).and_return([124, 'fixture cleanup deadline'])

    results = nil
    expect { results = group.evaluate }
      .to output(/qualification failure cleanup unsuccessful: status=124: fixture cleanup deadline/).to_stderr
    expect(results.first.exception).to equal(primary_error)
  end

  it 'executes the actual failure cleanup only against a disk-backed fixture' do
    add_failed_example
    context.instance_variable_set(:@qualification_events, %w[first second])
    command = nil
    allow(machine).to receive(:execute) do |value, **_options|
      command = value if value.include?('cleanup_status')
      [0, '']
    end
    expect(group.evaluate.first.exception).to equal(primary_error)

    Dir.mktmpdir('qualification-cleanup') do |dir|
      argv = Shellwords.split(command)
      expect(argv.first(6)).to eq(%w[timeout -k 1 25 sh -c])
      argv[-1] = argv.last.gsub('/run/livepatch-qualification', "#{dir}/population")
                     .gsub('/sys/', "#{dir}/sys/")
      online = File.join(dir, 'sys/devices/system/cpu/cpu3/online')
      trace = File.join(dir, 'sys/kernel/tracing/instances/livepatch_qualification/events/lp95_qualification')
      FileUtils.mkdir_p([File.join(dir, 'population'), File.dirname(online), File.join(dir, 'sys/kernel/tracing')])
      %w[first second].each do |event|
        FileUtils.mkdir_p(File.join(trace, event))
        File.write(File.join(trace, event, 'enable'), "1\n")
      end
      File.write(online, "0\n")

      _output, error, status = Open3.capture3(*argv)
      expect(status).to be_success, error
      expect(%w[stop sctp.release tun.stop].all? { |file| File.exist?(File.join(dir, 'population', file)) }).to be(true)
      expect(File.read(online)).to eq("1\n")
      %w[first second].each { |event| expect(File.read(File.join(trace, event, 'enable'))).to eq("0\n") }
      expect(File.read(File.join(dir, 'sys/kernel/tracing/kprobe_events')))
        .to eq("-:lp95_qualification/second\n-:lp95_qualification/first\n")
    end
  end

  it 'captures an activation exception before failure cleanup without replacing it' do
    guest = machine
    calls = []
    instance = context.new
    instance.define_singleton_method(:machine) { guest }
    instance.define_singleton_method(:capture_failed_patch_transition) { |*| nil }
    context.const_set(:CORRECTED_MODULE, '/fixture/corrected.ko')
    context.const_set(:CORRECTED_NAME, 'livepatch_7')
    context.const_set(:QUALIFICATION_TRANSITION_SECONDS, 1800)
    allow(guest).to receive(:execute).with(
      'LC_ALL=C insmod /fixture/corrected.ko 2>&1', timeout: a_value_within(1).of(1800)
    ).and_raise(primary_error)
    allow(instance).to receive(:capture_failed_patch_transition) { |*args| calls << [:capture, *args] }
    allow(guest).to receive(:execute).with(
      a_string_including('cleanup_status'), timeout: 30, shell: :diagnostics
    ) do
      calls << :cleanup
      [0, '']
    end

    group.add_example(TestRunner::Example.new(group, 'activation') { instance.qualification_activate('livepatch_6') })
    expect(group.evaluate.first.exception).to equal(primary_error)
    expect(instance).to have_received(:capture_failed_patch_transition).with(guest, 'livepatch_7', 1)
    expect(calls).to eq([[:capture, guest, 'livepatch_7', 1], :cleanup])
  end

  context 'when waiting for population progress' do
    def instance
      guest = machine
      context.new.tap { |value| value.define_singleton_method(:machine) { guest } }
    end

    def population
      { 'elapsed' => '88.087', 'wakeups' => '52864', 'fork_exec' => '826' }.tap do |values|
        4.times do |cpu|
          values["cpu_#{cpu}_progress"] = '100'
          values["cpu_#{cpu}_perf"] = '1000'
          values["cpu_#{cpu}_actual"] = cpu.to_s
        end
      end
    end

    def advanced
      population.to_h { |key, value| [key, key == 'elapsed' ? value : (Integer(value) + 1).to_s] }.merge(
        'elapsed' => '88.199', 'wakeups' => '52865', 'fork_exec' => '827',
        'cpu_0_actual' => '0', 'cpu_1_actual' => '1', 'cpu_2_actual' => '2', 'cpu_3_actual' => '3'
      )
    end

    def progress_command(cpu: nil)
      command = nil
      allow(machine).to receive(:wait_until_succeeds) do |value, **options|
        expect(options).to eq(timeout: 60)
        command = value
      end
      instance.qualification_wait_for_progress(population, cpu: cpu)
      command
    end

    def progress_status(command, values)
      Dir.mktmpdir('qualification-progress') do |dir|
        path = File.join(dir, 'population')
        File.write(path, values.map { |key, value| "#{key}=#{value}\n" }.join)
        actual = command.gsub('/run/livepatch-qualification/population', Shellwords.escape(path))
        _output, error, status = Open3.capture3('sh', '-c', actual)
        expect(error).to be_empty
        status.exitstatus
      end
    end

    it 'rejects the observed newer report with unchanged wakeups, then accepts full progress' do
      command = progress_command
      expect(progress_status(command, advanced.merge('wakeups' => '52864'))).to eq(1)
      expect(progress_status(command, advanced)).to eq(0)
    end

    it 'requires every already-asserted wake, fork, CPU and perf counter to advance' do
      command = progress_command
      instance.qualification_progress_keys(population).each do |key|
        expect(progress_status(command, advanced.merge(key => population.fetch(key)))).to eq(1), key
      end
    end

    it 'rejects a stale timestamp or a missing required counter' do
      command = progress_command
      expect(progress_status(command, advanced.merge('elapsed' => population.fetch('elapsed')))).to eq(1)
      expect(progress_status(command, advanced.except('wakeups'))).to eq(1)
    end

    it 'retains the loaded CPU identity requirement for hotplug within the same bound' do
      target = instance
      allow(target).to receive(:qualification_population).and_return(population)
      command = nil
      allow(machine).to receive(:wait_until_succeeds) do |value, **options|
        expect(options).to eq(timeout: 60)
        command = value
      end
      target.qualification_hotplug
      expect(machine).to have_received(:all_succeed).with(
        'echo 0 > /sys/devices/system/cpu/cpu3/online',
        'test "$(cat /sys/devices/system/cpu/cpu3/online)" = 0',
        'echo 1 > /sys/devices/system/cpu/cpu3/online',
        'test "$(getconf _NPROCESSORS_ONLN)" = 4'
      )
      expect(progress_status(command, advanced.merge('cpu_3_actual' => '0'))).to eq(1)
      expect(progress_status(command, advanced)).to eq(0)
    end

    it 'propagates the original bounded-wait failure rather than accepting a stalled population' do
      allow(machine).to receive(:wait_until_succeeds).with(anything, timeout: 60).and_raise(primary_error)
      expect { instance.qualification_wait_for_progress(population) }
        .to(raise_error { |error| expect(error).to equal(primary_error) })
    end
  end

  context 'when capturing a failed livepatch transition' do
    let(:machine) { instance_spy(OsVm::Machine, running?: true, execute: [0, ''], shells: [:diagnostics]) }
    let(:primary_error) { OsVm::TimeoutError.new('original transition deadline') }

    def transition_helper
      path = File.join(REPO_ROOT, 'tests/suite/kernel/livepatch-6.12.95-common.nix')
      source = File.read(path)
      Module.new.tap do |mod|
        %w[patch_dir capture_failed_patch_transition wait_for_patch].each do |name|
          method = source[/^    def self\.#{name}\b.*?^    end\n/m]
          raise "missing livepatch helper #{name}" unless method

          mod.module_eval(method.gsub("''${", '${'), path)
        end
      end
    end

    def capture_command(target)
      command = nil
      allow(machine).to receive(:wait_until_succeeds).and_raise(primary_error)
      allow(machine).to receive(:execute) do |value, **_options|
        command = value
        [0, '']
      end

      expect { transition_helper.wait_for_patch(machine, 'livepatch_7', target, timeout: 1800) }
        .to(raise_error { |error| expect(error).to equal(primary_error) })
      command
    end

    def run_capture(command, target, states, loader_state: 'R', sysrq_available: true, sysrq_status: 0)
      Dir.mktmpdir('livepatch-capture') do |dir|
        states.each do |tid, state|
          task = File.join(dir, 'proc/100/task', tid.to_s)
          FileUtils.mkdir_p(task)
          File.write(File.join(task, 'patch_state'), state)
          File.write(File.join(task, 'comm'), "fixture#{tid}\n")
          File.write(File.join(task, 'stack'), "fixture task stack\n")
        end
        worker = File.join(dir, 'proc/300/task/300')
        FileUtils.mkdir_p(worker)
        File.write(File.join(worker, 'wchan'), "wait_rcu_gp\n")
        File.write(File.join(worker, 'stack'), "fixture klp_complete_transition\n")
        running_worker = File.join(dir, 'proc/301/task/301')
        FileUtils.mkdir_p(running_worker)
        File.write(File.join(running_worker, 'wchan'), "0\n")
        File.write(File.join(running_worker, 'stack'), "fixture sched_dynamic_klp_disable\n")
        [350, 351].each do |tid|
          loader = File.join(dir, 'proc', tid.to_s, 'task', tid.to_s)
          FileUtils.mkdir_p(loader)
          File.write(File.join(loader, 'wchan'), "0\n")
          File.write(File.join(loader, 'stack'), "fixture module loader kernel stack\n")
        end
        sysrq_trigger = File.join(dir, 'proc/sysrq-trigger')
        File.write(sysrq_trigger, '') if sysrq_available
        control = File.join(dir, 'sys/kernel/livepatch/livepatch_7')
        FileUtils.mkdir_p(control)
        File.write(File.join(control, 'enabled'), "#{target}\n")
        File.write(File.join(control, 'transition'), "1\n")

        # Every proc/sysfs access is redirected into the temporary fixture. No VM,
        # host task inspection or actual kernel state change is involved.
        argv = Shellwords.split(command)
        fixture = argv.last.gsub('/proc/', "#{dir}/proc/")
                      .gsub('/sys/kernel/livepatch/', "#{dir}/sys/kernel/livepatch/")
        loaders = if loader_state
                    "350 350 #{loader_state} 0 insmod\n351 351 #{loader_state} 0 modprobe\n"
                  else
                    ''
                  end
        stubs = <<~SH
          ps() { printf '300 300 D wait_rcu_gp kworker/1:1\n301 301 R 0 kworker/2:1\n400 400 D futex_wait user\n#{loaders}'; }
          dmesg() { :; }
          timeout() {
            if test "$3" = 10 && test #{sysrq_status} != 0; then return #{sysrq_status}; fi
            command timeout "$@"
          }
        SH
        argv[-1] = stubs + fixture
        output, error, status = Open3.capture3(*argv)
        expect(status).to be_success, error
        yield output, File.exist?(sysrq_trigger) ? File.read(sysrq_trigger) : nil if block_given?
        output
      end
    end

    shared_examples 'defined opposite-state capture' do |target, tid, state|
      it "classifies target #{target} without undefined or invalid pending rows" do
        output = run_capture(
          capture_command(target), target,
          { 100 => "0\n", 101 => "1\n", 102 => "-1\n", 103 => "invalid\n", 104 => '' }
        )

        expect(output).to include("pending pid=100 tid=#{tid} comm=fixture#{tid} patch_state=#{state}")
        expect(output.scan(/^pending /).length).to eq(1)
        expect(output).to include(
          "coverage target=#{target} seen=5 read=4 unreadable=0 errors=1 undefined=1 invalid=1 pending=1"
        )
        expect(output).to include('transition worker candidate pid=300 tid=300')
        expect(output).to include('fixture klp_complete_transition')
        expect(output).to include('transition worker candidate pid=301 tid=301 stat=R wchan=0')
        expect(output).to include('fixture sched_dynamic_klp_disable')
        expect(output).not_to include('transition worker candidate pid=400')
        expect(output.index('transition worker candidate')).to be < output.index('pending pid=')
        expect(output).to include('--- transition after task scan ---')
        expect(output).to include('coverage_complete=1 sampled=1')
      end
    end

    it_behaves_like 'defined opposite-state capture', 1, 100, 0
    it_behaves_like 'defined opposite-state capture', 0, 101, 1

    it 'captures the running module loader before worker candidates' do
      output = run_capture(capture_command(1), 1, {})

      expect(output).to include('module loader candidate pid=350 tid=350 stat=R wchan=0 comm=insmod')
      expect(output).to include('fixture module loader kernel stack')
      expect(output.index('module loader candidate pid=')).to be < output.index('transition worker candidate pid=')
    end

    it 'requests one bounded CPU backtrace before scanning candidates or tasks' do
      command = capture_command(1)
      expect(Shellwords.split(command).last).to include("timeout -k 1 10 sh -c 'echo l > /proc/sysrq-trigger'")
      run_capture(command, 1, { 100 => "0\n" }) do |output, payload|
        expect(payload).to eq("l\n")
        expect(output.scan(/^--- failed transition CPU backtrace ---$/).length).to eq(1)
        expect(output).to include('CPU backtrace request status=0')
        expect(output.index('CPU backtrace request')).to be < output.index('module loader candidate pid=')
        expect(output.index('CPU backtrace request')).to be < output.index('pending pid=')
      end
    end

    it 'requests a CPU backtrace for a failed rollback without a running loader' do
      run_capture(capture_command(0), 0, {}, loader_state: 'S') do |output, payload|
        expect(payload).to eq("l\n")
        expect(output.scan(/^--- failed transition CPU backtrace ---$/).length).to eq(1)
        expect(output).to include('CPU backtrace request status=0')
        expect(output).to include('coverage_complete=1')
      end
    end

    it 'requests a CPU backtrace after the loader exited even when all visible tasks switched' do
      run_capture(capture_command(0), 0, { 100 => "0\n" }, loader_state: nil) do |output, payload|
        expect(payload).to eq("l\n")
        expect(output).not_to include('module loader candidate pid=')
        expect(output).to include('CPU backtrace request status=0')
        expect(output).to include('pending=0 coverage_complete=1 sampled=0')
        expect(output.index('CPU backtrace request')).to be < output.index('transition worker candidate pid=')
      end
    end

    it 'reports unavailable SysRq without abandoning the existing failed-transition capture' do
      run_capture(capture_command(1), 1, {}, sysrq_available: false) do |output, payload|
        expect(payload).to be_nil
        expect(output).to include('CPU backtrace request unavailable')
        expect(output).to include('coverage_complete=1')
      end
    end

    it 'does not run failure diagnostics after a successful transition wait' do
      transition_helper.wait_for_patch(machine, 'livepatch_7', 1, timeout: 1800)

      expect(machine).to have_received(:wait_until_succeeds)
      expect(machine).not_to have_received(:execute)
    end

    it 'retains a failed CPU-backtrace request status and continues the task scan' do
      run_capture(capture_command(1), 1, {}, sysrq_status: 124) do |output, payload|
        expect(payload).to eq('')
        expect(output).to include('CPU backtrace request status=124')
        expect(output).to include('coverage_complete=1')
      end
    end

    it 'does not restart a stopped VM to collect a failed transition' do
      allow(machine).to receive(:running?).and_return(false)
      allow(machine).to receive(:wait_until_succeeds).and_raise(primary_error)

      expect do
        expect { transition_helper.wait_for_patch(machine, 'livepatch_7', 1, timeout: 1800) }
          .to(raise_error { |error| expect(error).to equal(primary_error) })
      end.to output(/machine stopped/).to_stderr
      expect(machine).not_to have_received(:execute)
    end

    it 'reports zero coverage rather than counting an unmatched glob' do
      output = run_capture(capture_command(0), 0, {})

      expect(output).to include(
        'coverage target=0 seen=0 read=0 unreadable=0 errors=0 undefined=0 invalid=0 pending=0'
      )
    end

    it 'reports partial coverage during a large scan' do
      states = (1..1025).to_h { |tid| [tid, "0\n"] }
      output = run_capture(capture_command(0), 0, states)

      expect(output).to include('coverage target=0 seen=1024 read=1023')
      expect(output).to include('coverage target=0 seen=1025 read=1025')
      expect(output).to include('coverage_complete=0 sampled=0')
      expect(output).to include('coverage_complete=1 sampled=0')
    end

    it 'bounds pending stack samples while counting every observed thread' do
      states = (1..40).to_h { |tid| [tid, "0\n"] }
      output = run_capture(capture_command(1), 1, states)

      expect(output.scan(/^pending /).length).to eq(32)
      expect(output.scan(/^fixture task stack$/).length).to eq(32)
      expect(output).to include('seen=40 read=40 unreadable=0 errors=0 undefined=0 invalid=0 pending=40')
      expect(output).to include('coverage_complete=1 sampled=32')
    end

    it 'bounds the diagnostic child and uses the reserved channel before re-raising the deadline' do
      command = capture_command(1)

      expect(command).to start_with('timeout -k 1 290 sh -c ')
      expect(machine).to have_received(:execute).with(command, timeout: 300, shell: :diagnostics)
      expect(machine).to have_received(:wait_until_succeeds).with(anything, timeout: 1800)
      _output, error, status = Open3.capture3('sh', '-n', stdin_data: command)
      expect(status).to be_success, error
    end

    it 'reports an incomplete child capture without replacing the original deadline' do
      allow(machine).to receive(:wait_until_succeeds).and_raise(primary_error)
      allow(machine).to receive(:execute).and_return([124, 'partial coverage'])

      expect do
        expect { transition_helper.wait_for_patch(machine, 'livepatch_7', 1, timeout: 1800) }
          .to(raise_error { |error| expect(error).to equal(primary_error) })
      end.to output(/livepatch transition diagnostic incomplete: status=124/).to_stderr
    end

    it 'keeps the original channel for machines without a reserved shell' do
      allow(machine).to receive(:shells).and_return([])
      command = capture_command(0)

      expect(machine).to have_received(:execute).with(command, timeout: 300, shell: nil)
    end

    it 'preserves the original deadline when diagnostic execution fails' do
      allow(machine).to receive(:wait_until_succeeds).and_raise(primary_error)
      allow(machine).to receive(:execute).and_raise(OsVm::UnrecoverableTimeoutError.new('capture unavailable'))

      expect do
        expect { transition_helper.wait_for_patch(machine, 'livepatch_7', 0, timeout: 1800) }
          .to(raise_error { |error| expect(error).to equal(primary_error) })
      end.to output(/livepatch transition diagnostic unavailable.*capture unavailable/).to_stderr
    end

    it 'does not collect anything on a successful wait' do
      allow(machine).to receive(:wait_until_succeeds).and_return(nil)

      transition_helper.wait_for_patch(machine, 'livepatch_7', 0, timeout: 1800)

      expect(machine).to have_received(:wait_until_succeeds)
        .with('test ! -e /sys/kernel/livepatch/livepatch_7', timeout: 1800)
      expect(machine).not_to have_received(:execute)
    end
  end
end
