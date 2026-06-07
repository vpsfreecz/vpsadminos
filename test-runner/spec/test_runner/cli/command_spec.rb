# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TestRunner::Cli::Command do
  subject(:command) { described_class.new({}, opts, args) }

  def stub_test_script_list(scripts)
    list = instance_double(TestRunner::TestScriptList)

    allow(TestRunner::TestScriptList).to receive(:new).and_return(list)
    allow(list).to receive(:filter) { |&block| scripts.select(&block) }
  end

  let(:opts) do
    {
      'label' => [],
      'tag' => [],
      'jobs' => 2,
      'max-memory-mib' => nil,
      'max-shm-mib' => nil,
      'memory-reserve-mib' => nil,
      'shm-reserve-mib' => nil,
      'timeout' => 60,
      'stop-on-failure' => false,
      'destructive' => true,
      'fresh' => false,
      'system' => 'x86_64-linux',
      'test-config' => nil,
      'filter' => [],
      'state-dir' => nil
    }
  end
  let(:args) { [] }

  it 'prints selected script paths from list' do
    scripts = [
      instance_double(TestRunner::TestScript, path: 'suite/a'),
      instance_double(TestRunner::TestScript, path: 'suite/b')
    ]
    stub_test_script_list(scripts)

    expect(capture_stdout { command.list }).to eq("suite/a\nsuite/b\n")
  end

  it 'builds the executor with expected options and raises on unexpected results' do
    scripts = [instance_double(TestRunner::TestScript, path: 'suite/a')]
    executor = instance_double(TestRunner::Executor)
    result = instance_double(TestRunner::TestResult, unexpected_result?: true)
    stub_test_script_list(scripts)
    allow(TestRunner::Executor).to receive(:new).and_return(executor)
    allow(executor).to receive(:run).and_return([result])

    expect do
      command.test
    end.to raise_error(RuntimeError, 'one or more tests did not have expected results')

    expect(TestRunner::Executor).to have_received(:new).with(
      scripts,
      state_dir: '/tmp/os-test-runner',
      jobs: 2,
      max_memory_mib: nil,
      max_shm_mib: nil,
      memory_reserve_mib: nil,
      shm_reserve_mib: nil,
      default_timeout: 60,
      stop_on_failure: false,
      destructive: true,
      recreate_disks: false,
      system: 'x86_64-linux',
      test_config_path: nil
    )
  end

  it 'resolves scripts and starts debug evaluators interactively' do
    test = build_test(name: 'debug-test')
    script = test.test_scripts['default']
    list = instance_double(TestRunner::TestScriptList, by_path: script)
    evaluator = instance_double(TestRunner::TestEvaluator, interactive: nil)
    allow(TestRunner::TestScriptList).to receive(:new).and_return(list)
    allow(TestRunner::TestEvaluator).to receive(:new).and_return(evaluator)

    described_class.new({}, opts, ['suite/example']).debug

    expect(TestRunner::TestEvaluator).to have_received(:new).with(
      test,
      [script],
      system: 'x86_64-linux',
      test_config_path: nil,
      state_dir: '/tmp/os-test-runner/os-test-debug-test',
      sock_dir: '/tmp/os-test-runner/socks',
      default_timeout: 60,
      destructive: false
    )
    expect(evaluator).to have_received(:interactive)
  end

  it 'filters scripts by path pattern, labels, and tags' do
    matching = instance_double(
      TestRunner::TestScript,
      path: 'suite/example#default',
      labels: { 'tier' => '1' },
      tags: ['smoke']
    )
    nonmatching = instance_double(
      TestRunner::TestScript,
      path: 'suite/other#default',
      labels: { 'tier' => '2' },
      tags: ['slow']
    )
    allow(matching).to receive(:path_matches?).with('suite/*').and_return(true)
    allow(nonmatching).to receive(:path_matches?).with('suite/*').and_return(true)
    list = instance_double(TestRunner::TestScriptList)
    allow(TestRunner::TestScriptList).to receive(:new).and_return(list)
    allow(list).to receive(:filter) do |&block|
      [matching, nonmatching].select(&block)
    end

    filtered = described_class.new({}, opts.merge('label' => ['tier=1'], 'tag' => ['smoke']), []).send(
      :select_test_scripts,
      'suite/*'
    )

    expect(filtered).to eq([matching])
  end

  it 'filters scripts by metadata expression' do
    matching = instance_double(
      TestRunner::TestScript,
      path: 'suite/example#default',
      labels: { 'runtime' => 'short' },
      tags: %w[ci storage]
    )
    nonmatching = instance_double(
      TestRunner::TestScript,
      path: 'suite/other#default',
      labels: { 'runtime' => 'long' },
      tags: %w[ci manual]
    )
    allow(matching).to receive(:path_matches?).with('suite/*').and_return(true)
    allow(nonmatching).to receive(:path_matches?).with('suite/*').and_return(true)
    list = instance_double(TestRunner::TestScriptList)
    allow(TestRunner::TestScriptList).to receive(:new).and_return(list)
    allow(list).to receive(:filter) do |&block|
      [matching, nonmatching].select(&block)
    end

    filtered = described_class.new(
      {},
      opts.merge('filter' => ['tag=ci && (tag=vps || tag=storage) && runtime!=long']),
      []
    ).send(:select_test_scripts, 'suite/*')

    expect(filtered).to eq([matching])
  end

  it 'uses an explicit state dir when provided' do
    custom = described_class.new({}, opts.merge('state-dir' => '/var/tmp/run'), [])

    expect(custom.send(:state_dir)).to eq('/var/tmp/run')
  end

  it 'defaults the state dir under /tmp when not provided' do
    expect(command.send(:state_dir)).to eq('/tmp/os-test-runner')
  end

  it 'loads extension files only once when the extension directory exists' do
    with_tmpdir do |dir|
      extension_dir = File.join(dir, 'tests', 'runner', 'extensions')
      counter_path = File.join(dir, 'extension-count.txt')
      FileUtils.mkdir_p(extension_dir)
      File.write(
        File.join(extension_dir, 'one.rb'),
        <<~RUBY
          count =
            if File.exist?(#{counter_path.inspect})
              File.read(#{counter_path.inspect}).to_i
            else
              0
            end
          File.write(#{counter_path.inspect}, (count + 1).to_s)
        RUBY
      )

      Dir.chdir(dir) do
        command.send(:load_extensions)
        command.send(:load_extensions)
      end

      expect(File.read(counter_path)).to eq('1')
    end
  end

  it 'does nothing when the extension directory is absent' do
    with_tmpdir do |dir|
      Dir.chdir(dir) do
        expect { command.send(:load_extensions) }.not_to raise_error
      end
    end
  end
end
