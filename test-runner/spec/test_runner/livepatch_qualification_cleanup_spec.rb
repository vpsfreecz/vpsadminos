# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'open3'
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
    allow(machine).to receive(:execute).with(a_string_starting_with('touch ')).and_raise(cleanup_error)

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
    expect(machine).to have_received(:execute).exactly(5).times
  end

  context 'when capturing a failed livepatch transition' do
    let(:machine) { instance_spy(OsVm::Machine, execute: [0, '']) }
    let(:primary_error) { OsVm::TimeoutError.new('original transition deadline') }

    def transition_helper
      path = File.join(REPO_ROOT, 'tests/suite/kernel/livepatch-6.12.95-common.nix')
      source = File.read(path)
      Module.new.tap do |mod|
        %w[patch_dir wait_for_patch].each do |name|
          method = source[/^    def self\.#{name}\b.*?^    end\n/m]
          raise "missing livepatch helper #{name}" unless method

          mod.module_eval(method.gsub("''${", '${'), path)
        end
      end
    end

    def capture_command(target)
      command = nil
      allow(machine).to receive(:wait_until_succeeds).and_raise(primary_error)
      allow(machine).to receive(:execute) do |value|
        command = value
        [0, '']
      end

      expect { transition_helper.wait_for_patch(machine, 'livepatch_7', target, timeout: 1800) }
        .to(raise_error { |error| expect(error).to equal(primary_error) })
      command
    end

    def run_capture(command, target, states)
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
        control = File.join(dir, 'sys/kernel/livepatch/livepatch_7')
        FileUtils.mkdir_p(control)
        File.write(File.join(control, 'enabled'), "#{target}\n")
        File.write(File.join(control, 'transition'), "1\n")

        # Every proc/sysfs access is redirected into the temporary fixture. No VM,
        # host task inspection or actual kernel state change is involved.
        fixture = command.gsub('/proc/', "#{dir}/proc/")
                         .gsub('/sys/kernel/livepatch/', "#{dir}/sys/kernel/livepatch/")
        stubs = <<~'SH'
          ps() { printf '300 300 D wait_rcu_gp kworker/1:1\n301 301 R 0 kworker/2:1\n400 400 D futex_wait user\n'; }
          dmesg() { :; }
        SH
        output, error, status = Open3.capture3('sh', '-c', stubs + fixture)
        expect(status).to be_success, error
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
      end
    end

    it_behaves_like 'defined opposite-state capture', 1, 100, 0
    it_behaves_like 'defined opposite-state capture', 0, 101, 1

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
