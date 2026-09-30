# frozen_string_literal: true

require 'spec_helper'

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
end
