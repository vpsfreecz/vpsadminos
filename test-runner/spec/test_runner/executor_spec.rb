# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TestRunner::Executor do
  def build_executor(test_scripts, **opts)
    described_class.new(
      test_scripts,
      state_dir: '/tmp/os-test-runner',
      jobs: 1,
      max_memory_mib: nil,
      max_shm_mib: nil,
      max_cpus: nil,
      memory_reserve_mib: nil,
      shm_reserve_mib: nil,
      cpu_reserve: nil,
      default_timeout: 60,
      stop_on_failure: false,
      destructive: false,
      recreate_disks: false,
      system: 'x86_64-linux',
      test_config_path: nil,
      **opts
    )
  end

  def run_test_with_output(executor, test, scripts, lines:, exitstatus: 0)
    dir = executor.send(:test_state_dir, test)
    FileUtils.mkdir_p(dir)

    reader, writer = IO.pipe
    writer_copy = writer.dup
    child_pid = fork { exit exitstatus }
    writer_thread = Thread.new do
      lines.each { |line| writer_copy.puts(line) }
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
    allow(executor).to receive(:log)

    _i, test, = executor.send(:reserve_next_test)

    expect(test).to eq(large)
    expect(executor.send(:resource_pool).used.memory_mib).to eq(12_000)
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
