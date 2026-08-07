# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

RSpec.describe TestRunner::Executor do
  def build_executor(test_scripts, **opts)
    described_class.new(
      test_scripts,
      state_dir: '/tmp/os-test-runner',
      jobs: 1,
      jobs_auto: false,
      max_memory_mib: nil,
      max_shm_mib: nil,
      max_cpus: nil,
      memory_reserve_mib: nil,
      shm_reserve_mib: nil,
      cpu_reserve: nil,
      resource_detector: resource_detector,
      default_timeout: 60,
      stop_on_failure: false,
      destructive: false,
      recreate_disks: false,
      system: 'x86_64-linux',
      test_config_path: nil,
      **opts
    )
  end

  def run_test_with_output(executor, test, scripts, lines:, exitstatus: 0, writer_close_delay: 0)
    dir = executor.send(:test_state_dir, test)
    FileUtils.mkdir_p(dir)

    reader, writer = IO.pipe
    writer_copy = writer.dup
    child_pid = fork { exit exitstatus }
    writer_thread = Thread.new do
      lines.each { |line| writer_copy.puts(line) }
      sleep(writer_close_delay) if writer_close_delay > 0
      writer_copy.close
    end
    actual_wait = Process.method(:wait)
    logs = []

    allow(IO).to receive(:pipe).and_return([reader, writer])
    allow(Process).to receive(:fork).and_return(child_pid)
    allow(Process).to receive(:wait) { |pid| actual_wait.call(pid) }
    allow(OsVm::PortReservation).to receive(:get_ports).and_return([10_000, 10_001, 10_002, 10_003])
    allow(OsVm::PortReservation).to receive(:release_ports)
    allow(executor).to receive(:log) { |msg = ''| logs << msg }

    result = executor.send(:run_test, test, scripts, prefix: '[1/1]')

    writer_thread.join
    [result, logs, dir]
  end

  it 'fills the pending queue with scripts grouped by test' do
    test_a = build_test(path: 'suite/a', name: 'a', scripts: { 'smoke' => {}, 'full' => {} })
    test_b = build_test(path: 'suite/b', name: 'b')
    executor = build_executor(
      [test_a.test_scripts['smoke'], test_a.test_scripts['full'], test_b.test_scripts['default']]
    )
    queued = executor.send(:pending)

    grouped = queued.to_h { |_index, test, scripts| [test.path, scripts.map(&:name).sort] }
    expect(grouped).to eq(
      'suite/a' => %w[full smoke],
      'suite/b' => ['default']
    )
  end

  it 'starts the configured number of workers during a run' do
    test = build_test
    executor = build_executor([test.test_scripts['default']], jobs: 3)
    allow(executor).to receive(:start_worker)
    allow(executor).to receive(:wait_for_workers)
    allow(executor).to receive(:log)

    executor.run

    expect(executor).to have_received(:start_worker).with(0)
    expect(executor).to have_received(:start_worker).with(1)
    expect(executor).to have_received(:start_worker).with(2)
  end

  it 'retries test attempts until the result matches expectations' do
    test = build_test(attempts: 3)
    script = test.test_scripts['default']
    unexpected = TestRunner::TestResult.new(
      test,
      [TestRunner::TestScriptResult.new(script, false, 0.1)],
      true,
      0.1,
      '/tmp/state'
    )
    expected = TestRunner::TestResult.new(
      test,
      [TestRunner::TestScriptResult.new(script, true, 0.2)],
      true,
      0.2,
      '/tmp/state'
    )
    executor = build_executor([script])
    executor.instance_variable_set(:@pending, [[0, test, [script]]])
    allow(executor).to receive(:run_test_attempt).and_return(unexpected, expected)
    allow(executor).to receive(:sleep)

    executor.send(:run_worker, 0)

    expect(executor).to have_received(:run_test_attempt).twice
    expect(executor.results.first).to be_successful
    expect(executor.results.first.elapsed_time).to be_within(0.001).of(0.3)
  end

  it 'retries only scripts with unexpected results' do
    test = build_test(
      scripts: {
        'stable' => {},
        'flaky' => { 'attempts' => 3 }
      }
    )
    stable = test.test_scripts['stable']
    flaky = test.test_scripts['flaky']
    first = TestRunner::TestResult.new(
      test,
      [
        TestRunner::TestScriptResult.new(stable, true, 0.1),
        TestRunner::TestScriptResult.new(flaky, false, 0.2)
      ],
      true,
      0.3,
      '/tmp/state'
    )
    second = TestRunner::TestResult.new(
      test,
      [TestRunner::TestScriptResult.new(flaky, true, 0.4)],
      true,
      0.4,
      '/tmp/state'
    )
    executor = build_executor([stable, flaky])
    executor.instance_variable_set(:@pending, [[0, test, [stable, flaky]]])
    allow(executor).to receive(:run_test_attempt).and_return(first, second)
    allow(executor).to receive(:sleep)

    executor.send(:run_worker, 0)

    expect(executor).to have_received(:run_test_attempt).with(0, test, [stable, flaky], 0)
    expect(executor).to have_received(:run_test_attempt).with(0, test, [flaky], 1)
    expect(executor.results.first.script_results.map(&:test_script)).to eq([stable, flaky])
    expect(executor.results.first).to be_successful
  end

  it 'runs a smaller pending test when the first pending test does not fit resources' do
    large = build_test(
      path: 'suite/large',
      resources: {
        'machines' => 2,
        'memoryMiB' => 12_000,
        'shmMiB' => 12_000,
        'maxMachineMemoryMiB' => 6000,
        'cpus' => 8
      }
    )
    small = build_test(
      path: 'suite/small',
      resources: {
        'machines' => 1,
        'memoryMiB' => 1000,
        'shmMiB' => 1000,
        'maxMachineMemoryMiB' => 1000,
        'cpus' => 1
      }
    )
    executor = build_executor(
      [large.test_scripts['default'], small.test_scripts['default']],
      max_memory_mib: 10_000,
      max_shm_mib: 10_000,
      memory_reserve_mib: 0,
      shm_reserve_mib: 0
    )
    pool = executor.send(:resource_pool)
    pool.reserve(TestRunner::TestResources.new(memory_mib: 9000, shm_mib: 9000))
    executor.instance_variable_set(
      :@pending,
      [
        [0, large, [large.test_scripts['default']]],
        [1, small, [small.test_scripts['default']]]
      ]
    )
    allow(executor).to receive(:log)

    _i, test, = executor.send(:reserve_next_test)

    expect(test).to eq(small)
    expect(pool.used.memory_mib).to eq(10_000)
  end

  it 'runs a smaller pending test when the first pending test exceeds the cpu cap' do
    cpu_heavy = build_test(
      path: 'suite/cpu-heavy',
      resources: {
        'machines' => 2,
        'memoryMiB' => 2000,
        'shmMiB' => 2000,
        'maxMachineMemoryMiB' => 1000,
        'cpus' => 8
      }
    )
    small = build_test(
      path: 'suite/small',
      resources: {
        'machines' => 1,
        'memoryMiB' => 1000,
        'shmMiB' => 1000,
        'maxMachineMemoryMiB' => 1000,
        'cpus' => 2
      }
    )
    executor = build_executor(
      [cpu_heavy.test_scripts['default'], small.test_scripts['default']],
      max_memory_mib: 16_000,
      max_shm_mib: 16_000,
      max_cpus: 4,
      memory_reserve_mib: 0,
      shm_reserve_mib: 0,
      cpu_reserve: 0
    )
    pool = executor.send(:resource_pool)
    pool.reserve(TestRunner::TestResources.new(cpus: 2))
    executor.instance_variable_set(
      :@pending,
      [
        [0, cpu_heavy, [cpu_heavy.test_scripts['default']]],
        [1, small, [small.test_scripts['default']]]
      ]
    )
    allow(executor).to receive(:log)

    _i, test, = executor.send(:reserve_next_test)

    expect(test).to eq(small)
    expect(pool.used.cpus).to eq(4)
  end

  it 'does not refresh resource capacity from waiting scheduler workers' do
    pending_test = build_test(
      path: 'suite/pending',
      resources: {
        'machines' => 1,
        'memoryMiB' => 2000,
        'shmMiB' => 1000,
        'maxMachineMemoryMiB' => 2000,
        'cpus' => 1
      }
    )
    executor = build_executor(
      [pending_test.test_scripts['default']],
      memory_reserve_mib: 0,
      shm_reserve_mib: 0,
      resource_detector: resource_detector(
        memory_mib: [4000, 6000],
        shm_mib: 2000,
        cpus: 2
      )
    )
    pool = executor.send(:resource_pool)
    pool.reserve(TestRunner::TestResources.new(memory_mib: 3000, shm_mib: 0))
    cv = instance_double(ConditionVariable)
    allow(executor).to receive(:log)
    allow(cv).to receive(:wait) do
      executor.instance_variable_set(:@stop_work, true)
    end
    executor.instance_variable_set(:@scheduler_cv, cv)

    reserved = executor.send(:reserve_next_test)

    expect(reserved).to be_nil
    expect(pool.memory_mib).to eq(4000)
  end

  it 'runs a pending test after the resource monitor refreshes cpu capacity' do
    pending_test = build_test(
      path: 'suite/pending',
      resources: {
        'machines' => 1,
        'memoryMiB' => 2000,
        'shmMiB' => 1000,
        'maxMachineMemoryMiB' => 2000,
        'cpus' => 1
      }
    )
    executor = build_executor(
      [pending_test.test_scripts['default']],
      memory_reserve_mib: 0,
      shm_reserve_mib: 0,
      resource_refresh_interval: 0.01,
      resource_detector: resource_detector(
        memory_mib: 6000,
        shm_mib: 2000,
        cpus: [1, 2]
      )
    )
    pool = executor.send(:resource_pool)
    pool.reserve(TestRunner::TestResources.new(memory_mib: 3000, shm_mib: 0, cpus: 1))
    allow(executor).to receive(:log)

    thread = Thread.new { executor.send(:reserve_next_test) }
    begin
      executor.send(:start_resource_monitor)
      _i, test, = Timeout.timeout(1) { thread.value }
    ensure
      executor.send(:stop_resource_monitor)
      executor.send(:stop_work!)
      thread.join
    end

    expect(test).to eq(pending_test)
    expect(pool.used.memory_mib).to eq(5000)
    expect(pool.used.cpus).to eq(2)
  end

  it 'does not start another test when refreshed cpu capacity decreases below current usage' do
    small = build_test(
      path: 'suite/small',
      resources: {
        'machines' => 1,
        'memoryMiB' => 1000,
        'shmMiB' => 1000,
        'maxMachineMemoryMiB' => 1000,
        'cpus' => 1
      }
    )
    executor = build_executor(
      [small.test_scripts['default']],
      resource_detector: resource_detector(cpus: [8, 2])
    )
    pool = executor.send(:resource_pool)
    pool.reserve(TestRunner::TestResources.new(cpus: 4))
    allow(executor).to receive(:log)

    executor.send(:refresh_resource_capacity)

    expect(executor.send(:schedulable_test_index)).to be_nil
  end

  it 'logs refreshed resource limits only when formatted limits change' do
    test = build_test
    executor = build_executor(
      [test.test_scripts['default']],
      resource_detector: resource_detector(cpus: [2, 2, 4, 4])
    )
    logs = []
    allow(executor).to receive(:log) { |msg| logs << msg }

    3.times { executor.send(:refresh_resource_capacity) }

    expect(logs).to contain_exactly(
      a_string_starting_with('Resource limits updated:').and(including('cpus=0/6'))
    )
  end

  it 'logs passing suite status with expected result categories and progress counts' do
    expected_successful = instance_double(
      TestRunner::TestResult,
      expected_to_succeed?: true,
      successful?: true,
      expected_to_fail?: false,
      failed?: false,
      script_results: []
    )
    expected_failed = instance_double(
      TestRunner::TestResult,
      expected_to_succeed?: false,
      successful?: false,
      expected_to_fail?: true,
      failed?: true,
      script_results: []
    )
    running_test = build_test(path: 'suite/running', name: 'running')
    pending_test = build_test(path: 'suite/pending', name: 'pending')
    executor = build_executor([running_test.test_scripts['default'], pending_test.test_scripts['default']])
    logs = []
    allow(executor).to receive(:log) { |msg| logs << msg }
    executor.instance_variable_set(:@results, [expected_successful, expected_failed])
    executor.send(:mark_test_running, 0, running_test)
    executor.instance_variable_set(:@pending, [[1, pending_test, [pending_test.test_scripts['default']]]])

    executor.send(:log_status)

    expect(logs).to contain_exactly(
      'Status: passing; 1 succeeded as expected, 1 failed as expected, ' \
      '0 unexpectedly failed, 0 unexpectedly succeeded; 1 running, 1 remaining'
    )
  end

  it 'logs failed suite status with unexpected result categories and progress counts' do
    expected_successful = instance_double(
      TestRunner::TestResult,
      expected_to_succeed?: true,
      successful?: true,
      expected_to_fail?: false,
      failed?: false,
      script_results: []
    )
    expected_failed = instance_double(
      TestRunner::TestResult,
      expected_to_succeed?: false,
      successful?: false,
      expected_to_fail?: true,
      failed?: true,
      script_results: []
    )
    unexpected_failed = instance_double(
      TestRunner::TestResult,
      expected_to_succeed?: true,
      successful?: false,
      expected_to_fail?: false,
      failed?: true,
      script_results: [
        instance_double(
          TestRunner::TestScriptResult,
          unexpected_result?: true,
          successful?: false,
          failed?: true,
          test_script: instance_double(TestRunner::TestScript, path: 'suite/unexpected-failed')
        )
      ]
    )
    unexpected_successful = instance_double(
      TestRunner::TestResult,
      expected_to_succeed?: false,
      successful?: true,
      expected_to_fail?: true,
      failed?: false,
      script_results: [
        instance_double(
          TestRunner::TestScriptResult,
          unexpected_result?: true,
          successful?: true,
          failed?: false,
          test_script: instance_double(TestRunner::TestScript, path: 'suite/unexpected-successful')
        )
      ]
    )
    running_test = build_test(path: 'suite/running', name: 'running')
    pending_test = build_test(path: 'suite/pending', name: 'pending')
    executor = build_executor([running_test.test_scripts['default'], pending_test.test_scripts['default']])
    logs = []
    allow(executor).to receive(:log) { |msg| logs << msg }
    executor.instance_variable_set(
      :@results,
      [expected_successful, expected_failed, unexpected_failed, unexpected_successful]
    )
    executor.send(:mark_test_running, 0, running_test)
    executor.instance_variable_set(:@pending, [[1, pending_test, [pending_test.test_scripts['default']]]])

    executor.send(:log_status)

    expect(logs).to contain_exactly(
      'Status: failed; 1 succeeded as expected, 1 failed as expected, ' \
      '1 unexpectedly failed, 1 unexpectedly succeeded; 1 running, 1 remaining',
      'Unexpectedly failed test scripts: suite/unexpected-failed',
      'Unexpectedly successful test scripts: suite/unexpected-successful'
    )
  end

  it 'classifies mixed unexpected script paths by their own outcomes' do
    test = build_test(
      path: 'suite/mixed',
      scripts: {
        'unexpected-failed' => {},
        'unexpected-successful' => { 'expectFailure' => true }
      }
    )
    failed_script = test.test_scripts.fetch('unexpected-failed')
    successful_script = test.test_scripts.fetch('unexpected-successful')
    result = TestRunner::TestResult.new(
      test,
      [
        TestRunner::TestScriptResult.new(failed_script, false, 0.1),
        TestRunner::TestScriptResult.new(successful_script, true, 0.1)
      ],
      false,
      0.2,
      '/tmp/state'
    )
    executor = build_executor([failed_script, successful_script])
    logs = []
    allow(executor).to receive(:log) { |msg| logs << msg }
    executor.instance_variable_set(:@results, [result])
    executor.instance_variable_set(:@pending, [])

    executor.send(:log_status)

    expect(logs).to contain_exactly(
      'Status: failed; 0 succeeded as expected, 0 failed as expected, ' \
      '1 unexpectedly failed, 0 unexpectedly succeeded; 0 running, 0 remaining',
      'Unexpectedly failed test scripts: suite/mixed#unexpected-failed',
      'Unexpectedly successful test scripts: suite/mixed#unexpected-successful'
    )
  end

  it 'does not start the suite status monitor when the interval is disabled' do
    test = build_test
    executor = build_executor([test.test_scripts['default']], status_interval: 0)
    allow(executor).to receive(:start_worker)
    allow(executor).to receive(:wait_for_workers)
    allow(executor).to receive(:log)

    executor.run

    expect(executor.instance_variable_get(:@status_monitor)).to be_nil
  end

  it 'stops the suite status monitor without waiting for the full interval' do
    executor = build_executor([], status_interval: 60)
    allow(executor).to receive(:log_status)

    executor.send(:start_status_monitor)

    expect do
      Timeout.timeout(1) { executor.send(:stop_status_monitor) }
    end.not_to raise_error
    expect(executor.instance_variable_get(:@status_monitor)).to be_nil
  end

  it 'runs an oversized pending test alone to avoid scheduler deadlock' do
    large = build_test(
      path: 'suite/large',
      resources: {
        'machines' => 1,
        'memoryMiB' => 12_000,
        'shmMiB' => 12_000,
        'maxMachineMemoryMiB' => 12_000,
        'cpus' => 4
      }
    )
    executor = build_executor(
      [large.test_scripts['default']],
      max_memory_mib: 10_000,
      max_shm_mib: 10_000,
      memory_reserve_mib: 0,
      shm_reserve_mib: 0
    )
    logs = []
    allow(executor).to receive(:log) { |msg| logs << msg }

    _i, test, = executor.send(:reserve_next_test)

    expect(test).to eq(large)
    expect(executor.send(:resource_pool).used.memory_mib).to eq(12_000)
    expect(logs).to include(
      a_string_including(
        'WARNING: Test suite/large requests resources beyond the scheduler limits',
        'requested: machines=1, memory=11.7 GiB, shm=11.7 GiB, cpus=4',
        'running it alone may exhaust the host'
      )
    )
  end

  it 'releases reserved resources after a test finishes' do
    test = build_test(
      resources: {
        'machines' => 1,
        'memoryMiB' => 1000,
        'shmMiB' => 1000,
        'maxMachineMemoryMiB' => 1000,
        'cpus' => 1
      }
    )
    script = test.test_scripts['default']
    result = TestRunner::TestResult.new(
      test,
      [TestRunner::TestScriptResult.new(script, true, 0.1)],
      true,
      0.1,
      '/tmp/state'
    )
    executor = build_executor(
      [script],
      max_memory_mib: 1000,
      max_shm_mib: 1000,
      memory_reserve_mib: 0,
      shm_reserve_mib: 0
    )
    allow(executor).to receive(:run_test_with_retries).and_return(result)
    allow(executor).to receive(:log)

    executor.send(:run_worker, 0)

    expect(executor.send(:resource_pool).used.memory_mib).to eq(0)
    expect(executor.send(:resource_pool).used.shm_mib).to eq(0)
    expect(executor.send(:resource_pool).running).to eq(0)
  end

  it 'stops work after unexpected results when stop_on_failure is enabled' do
    test = build_test
    script = test.test_scripts['default']
    result = instance_double(
      TestRunner::TestResult,
      elapsed_time: 1.0,
      expected_result?: false,
      successful?: false,
      failed?: true,
      state_dir: '/tmp/state'
    )
    executor = build_executor([script], stop_on_failure: true)
    allow(executor).to receive(:run_test).and_return(result)
    allow(executor).to receive(:log)

    executor.send(:run_test_attempt, 0, test, [script], 0)

    expect(executor.send(:stop_work?)).to be(true)
  end

  it 'parses example and script json lines from run_test' do
    test = build_test
    script = test.test_scripts['default']
    executor = build_executor([script])
    result, logs, dir = run_test_with_output(
      executor,
      test,
      [script],
      lines: [
        JSON.dump(
          'type' => 'example',
          'script' => 'default',
          'example' => 'suite/example works',
          'progress' => 1,
          'total' => 1,
          'success' => true,
          'pending' => false,
          'skip' => false,
          'elapsed_time' => 0.1
        ),
        JSON.dump(
          'type' => 'script',
          'script' => 'default',
          'success' => true,
          'elapsed_time' => 0.2,
          'expected_to_succeed' => true,
          'expected_result' => true
        )
      ]
    )

    expect(result.script_results.length).to eq(1)
    expect(result.script_results.first).to be_successful
    expect(logs.any? { |msg| msg.include?("Example [1/1] 'suite/example works' succeeded") }).to be(true)
    expect(File.read(File.join(dir, 'test-result.txt')).strip).to eq('expected_success')
  end

  it 'hides the per-test heartbeat by default' do
    test = build_test
    script = test.test_scripts['default']
    executor = build_executor([script])
    stub_const('TestRunner::Executor::TEST_HEARTBEAT_INTERVAL', 0.01)

    _result, logs = run_test_with_output(
      executor,
      test,
      [script],
      lines: [],
      writer_close_delay: 0.05
    )

    expect(logs.grep(/still running after/)).to be_empty
  end

  it 'logs the per-test heartbeat in verbose mode' do
    test = build_test
    script = test.test_scripts['default']
    executor = build_executor([script], verbose: true)
    stub_const('TestRunner::Executor::TEST_HEARTBEAT_INTERVAL', 0.01)

    _result, logs = run_test_with_output(
      executor,
      test,
      [script],
      lines: [],
      writer_close_delay: 0.05
    )

    expect(logs.any? { |msg| msg.include?("Test 'suite/example' still running after") }).to be(true)
  end

  it 'complements missing script results with failed placeholders' do
    test = build_test
    script = test.test_scripts['default']
    executor = build_executor([script])
    result, = run_test_with_output(executor, test, [script], lines: [], exitstatus: 1)

    expect(result.script_results.length).to eq(1)
    expect(result.script_results.first).to be_failed
    expect(result.script_results.first.elapsed_time).to eq(-1)
  end

  it 'returns the last non-empty line from a file and tolerates missing files' do
    with_tmpdir do |dir|
      path = File.join(dir, 'test.log')
      File.write(path, "first\n\nsecond\n")
      executor = build_executor([])

      expect(executor.send(:last_nonempty_line, path)).to eq('second')
      expect(executor.send(:last_nonempty_line, File.join(dir, 'missing.log'))).to be_nil
    end
  end

  it 'serializes log output through the mutex' do
    executor = build_executor([])
    mutex = instance_double(Mutex)
    allow(mutex).to receive(:synchronize).and_yield
    executor.instance_variable_set(:@mutex, mutex)

    output = capture_stdout { executor.send(:log, 'hello') }

    expect(mutex).to have_received(:synchronize)
    expect(output).to include('hello')
  end

  it 'derives unique state directories from the test path, not only the display name' do
    executor = build_executor([], state_dir: '/tmp/os-test-runner')
    first = instance_double(TestRunner::Test, name: 'v1', path: 'osctl/ct-exec-v1')
    second = instance_double(TestRunner::Test, name: 'v1', path: 'osctl/ct-runscript-v1')

    expect(executor.send(:test_state_dir, first)).not_to eq(executor.send(:test_state_dir, second))
  end

  it 'uses the test path as the multicast reservation key' do
    test = build_test(path: 'osctl/ct-exec-v1', name: 'v1')
    script = test.test_scripts['default']
    executor = build_executor([script])

    run_test_with_output(executor, test, [script], lines: [])

    expect(OsVm::PortReservation).to have_received(:get_ports).with(key: 'test:osctl/ct-exec-v1', size: 4)
    expect(OsVm::PortReservation).to have_received(:release_ports).with(key: 'test:osctl/ct-exec-v1')
  end
end
