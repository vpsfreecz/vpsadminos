# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TestRunner::TestEvaluator do
  def config_double(data)
    instance_double(TestRunner::TestConfig).tap do |cfg|
      allow(cfg).to receive(:[]) { |key| data[key] }
      allow(cfg).to receive(:dig) { |*keys| data.dig(*keys) }
    end
  end

  def build_evaluator(test: build_test, scripts: [test.test_scripts['default']], config_data: nil, machines: [], **opts)
    config_data ||= {
      'machines' => {},
      'framework' => {},
      'testScripts' => scripts.to_h do |script|
        [script.name, { 'script' => '' }]
      end
    }

    allow(TestRunner::TestConfig).to receive(:build).and_return(config_double(config_data))
    machine_queue = machines.dup
    allow(OsVm::MachineConfig).to receive(:from_config) do |cfg|
      instance_double(OsVm::MachineConfig, spin: cfg.fetch('spin', 'vpsadminos'))
    end
    allow(OsVm::VpsadminosMachine).to receive(:new) { machine_queue.shift || build_fake_machine }
    allow(OsVm::NixosMachine).to receive(:new) { machine_queue.shift || build_fake_machine }

    described_class.new(
      test,
      scripts,
      state_dir: '/tmp/state',
      sock_dir: '/tmp/sock',
      default_timeout: 10,
      destructive: true,
      recreate_disks: false,
      **opts
    )
  end

  it 'rejects scripts from a different test' do
    test = build_test(path: 'suite/a', name: 'a')
    other = build_test(path: 'suite/b', name: 'b')

    expect do
      described_class.new(
        test,
        [other.test_scripts['default']],
        state_dir: '/tmp/state',
        sock_dir: '/tmp/sock',
        default_timeout: 10,
        destructive: true,
        recreate_disks: false
      )
    end.to raise_error(ArgumentError, 'script default is not of test suite/a')
  end

  it 'builds machine accessors from machine config' do
    machine = build_fake_machine
    evaluator = build_evaluator(
      config_data: {
        'machines' => {
          'alpha' => { 'spin' => 'vpsadminos' }
        },
        'framework' => {},
        'testScripts' => { 'default' => { 'script' => '' } }
      },
      machines: [machine]
    )

    expect(evaluator.machines['alpha']).to eq(machine)
    expect(evaluator.alpha).to eq(machine)
  end

  it 'returns framework test_config data' do
    evaluator = build_evaluator(
      config_data: {
        'machines' => {},
        'framework' => { 'testConfig' => { 'foo' => 'bar' } },
        'testScripts' => { 'default' => { 'script' => '' } }
      }
    )

    expect(evaluator.test_config).to eq('foo' => 'bar')
  end

  it 'runs scripts and yields example hashes and script results' do
    test = build_test
    script = test.test_scripts['default']
    evaluator = build_evaluator(
      test:,
      scripts: [script],
      config_data: {
        'machines' => {},
        'framework' => {},
        'testScripts' => {
          'default' => {
            'script' => <<~RUBY
              describe 'suite/example' do
                it('works') { expect(1).to eq(1) }
              end
            RUBY
          }
        }
      }
    )
    events = []

    results = evaluator.run { |event| events << event }

    expect(results['default']).to be_successful
    expect(events.first).to include('type' => 'example', 'script' => 'default', 'success' => true)
    expect(events.last).to be_a(TestRunner::TestScriptResult)
  end

  it 'runs test scripts in parallel up to test_script_jobs' do
    with_tmpdir do |dir|
      test = build_test(
        test_script_jobs: 2,
        scripts: {
          'a' => {},
          'b' => {}
        }
      )
      scripts = [test.test_scripts['a'], test.test_scripts['b']]
      ready_a = File.join(dir, 'a.ready')
      ready_b = File.join(dir, 'b.ready')
      observed_shells = File.join(dir, 'shells.log')
      script = lambda do |name, ready|
        <<~RUBY
          @script_private = #{name.inspect}
          File.write(#{ready.inspect}, "ready\\n")
          File.open(#{observed_shells.inspect}, 'a') do |f|
            f.puts(Thread.current[OsVm::Machine::SHELL_INDEX_KEY])
          end
          wait_for_block(name: 'parallel scripts', timeout: 2) do
            File.exist?(#{ready_a.inspect}) && File.exist?(#{ready_b.inspect})
          end
          raise 'script context leaked' unless @script_private == #{name.inspect}
        RUBY
      end
      evaluator = build_evaluator(
        test:,
        scripts:,
        config_data: {
          'machines' => {},
          'framework' => {},
          'testScripts' => {
            'a' => { 'script' => script.call('a', ready_a) },
            'b' => { 'script' => script.call('b', ready_b) }
          }
        }
      )

      results = evaluator.run

      expect(results.values).to all(be_successful)
      expect(File.readlines(observed_shells, chomp: true).sort).to eq(%w[0 1])
    end
  end

  it 'calls after_test_script_run and after_test_run hooks' do
    script_events = []
    test_events = []
    TestRunner::Hook.subscribe(:after_test_script_run) { |script_result:, **| script_events << script_result }
    TestRunner::Hook.subscribe(:after_test_run) { |test_result:, **| test_events << test_result }
    evaluator = build_evaluator(
      config_data: {
        'machines' => {},
        'framework' => {},
        'testScripts' => {
          'default' => {
            'script' => "describe('suite/example') { it('works') { expect(1).to eq(1) } }"
          }
        }
      }
    )

    evaluator.run

    expect(script_events.length).to eq(1)
    expect(test_events.length).to eq(1)
  end

  it 'supports describe/context/it/pending/skip/before/after in test scripts' do
    with_tmpdir do |dir|
      event_path = File.join(dir, 'dsl-events.log')
      evaluator = build_evaluator(
        config_data: {
          'machines' => {},
          'framework' => {},
          'testScripts' => {
            'default' => {
              'script' => <<~RUBY
                record = ->(name) { File.open(#{event_path.inspect}, 'a') { |f| f.puts(name) } }
                configure_examples { |c| c.default_order = :defined }
                before(:suite) { record.call('before_suite') }
                after(:suite) { record.call('after_suite') }
                describe 'outer', order: :defined do
                  before(:context) { record.call('before_context') }
                  after(:context) { record.call('after_context') }
                  before(:example) { record.call('before_example') }
                  after(:example) { record.call('after_example') }

                  it('works') { record.call('example') }
                  pending('later') { raise RSpec::Expectations::ExpectationNotMetError, 'pending' }
                  skip('skip')

                  context 'inner' do
                    it('nested') { record.call('nested') }
                  end
                end
              RUBY
            }
          }
        }
      )

      expect { evaluator.run }.not_to raise_error
      expect(File.readlines(event_path, chomp: true)).to include(
        'before_suite',
        'before_context',
        'before_example',
        'example',
        'after_example',
        'nested',
        'after_context',
        'after_suite'
      )
    end
  end

  it 'generates unique container ids and raises on exhaustion' do
    evaluator = build_evaluator

    expect(evaluator.get_container_id('ct')).not_to eq(evaluator.get_container_id('ct'))

    evaluator.instance_variable_set(:@used_container_ids, ['ct-aaaa'])
    allow(SecureRandom).to receive(:hex).and_return(*Array.new(10, 'aaaa'))
    allow(evaluator).to receive(:sleep)

    expect do
      evaluator.get_container_id('ct')
    end.to raise_error(RuntimeError, 'Unable to generate unique container id')
  end

  it 'waits for a truthy block result' do
    evaluator = build_evaluator
    calls = 0
    allow(evaluator).to receive(:sleep)

    result = evaluator.wait_for_block(name: 'thing') do
      calls += 1
      calls > 1 && :ready
    end

    expect(result).to eq(:ready)
  end

  it 'times out while waiting for a truthy block result' do
    evaluator = build_evaluator

    expect do
      evaluator.wait_for_block(name: 'thing', timeout: 0) { false }
    end.to raise_error(OsVm::TimeoutError, 'Timeout occurred while waiting for thing')
  end

  it 'waits until a block succeeds' do
    evaluator = build_evaluator
    calls = 0
    allow(evaluator).to receive(:sleep)

    result = evaluator.wait_until_block_succeeds(name: 'thing') do
      calls += 1
      raise OsVm::CommandFailed if calls == 1

      true
    end

    expect(result).to be(true)
  end

  it 'times out while waiting for a block to succeed' do
    evaluator = build_evaluator

    expect do
      evaluator.wait_until_block_succeeds(name: 'thing', timeout: 0) { raise OsVm::CommandFailed }
    end.to raise_error(OsVm::TimeoutError, 'Timeout occurred while waiting for thing to succeed')
  end

  it 'waits until a block fails' do
    evaluator = build_evaluator
    calls = 0
    allow(evaluator).to receive(:sleep)

    result = evaluator.wait_until_block_fails(name: 'thing') do
      calls += 1
      raise OsVm::CommandFailed if calls == 2

      true
    end

    expect(result).to be(true)
  end

  it 'times out while waiting for a block to fail' do
    evaluator = build_evaluator

    expect do
      evaluator.wait_until_block_fails(name: 'thing', timeout: 0) { true }
    end.to raise_error(OsVm::TimeoutError, 'Timeout occurred while waiting for thing to fail')
  end

  it 'stops runnable machines and always kills, finalizes, and cleans up' do
    evaluator = build_evaluator
    runnable = instance_spy(FakeMachine, running?: true, can_execute?: true, stop: nil, kill: nil, destroy: nil, finalize: nil, cleanup: nil)
    non_exec = instance_spy(FakeMachine, running?: true, can_execute?: false, stop: nil, kill: nil, destroy: nil, finalize: nil, cleanup: nil)
    stopped = instance_spy(FakeMachine, running?: false, can_execute?: false, stop: nil, kill: nil, destroy: nil, finalize: nil, cleanup: nil)
    evaluator.instance_variable_set(:@machines, { 'a' => runnable, 'b' => non_exec, 'c' => stopped })

    evaluator.send(:do_run) { nil }

    expect(runnable).to have_received(:stop)
    expect(non_exec).not_to have_received(:stop)
    expect(stopped).not_to have_received(:stop)
    expect([runnable, non_exec, stopped]).to all(have_received(:kill))
    expect([runnable, non_exec, stopped]).to all(have_received(:destroy))
    expect([runnable, non_exec, stopped]).to all(have_received(:finalize))
    expect([runnable, non_exec, stopped]).to all(have_received(:cleanup))
  end

  it 'prefers hook machine class overrides before spin-based defaults' do
    evaluator = build_evaluator
    config = instance_double(OsVm::MachineConfig, spin: 'vpsadminos')
    klass = Class.new
    TestRunner::Hook.subscribe(:machine_class_for) { klass }

    expect(evaluator.send(:machine_class_for, config)).to eq(klass)
    expect(evaluator.send(:machine_class_for, instance_double(OsVm::MachineConfig, spin: 'nixos'))).to eq(klass)
  end

  it 'falls back to machine spin when no hook override is present' do
    evaluator = build_evaluator

    expect(evaluator.send(:machine_class_for, instance_double(OsVm::MachineConfig, spin: 'vpsadminos'))).to eq(OsVm::VpsadminosMachine)
    expect(evaluator.send(:machine_class_for, instance_double(OsVm::MachineConfig, spin: 'nixos'))).to eq(OsVm::NixosMachine)
  end
end
