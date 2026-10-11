# frozen_string_literal: true

require 'spec_helper'
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
end
