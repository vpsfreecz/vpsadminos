# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TestRunner::Cli::Command do
  subject(:command) { described_class.new({}, opts, args) }

  def stub_test_script_list(scripts)
    list = instance_double(TestRunner::TestScriptList)

    allow(TestRunner::TestScriptList).to receive(:new).and_return(list)
    allow(list).to receive(:matching).and_return(scripts)
  end

  let(:opts) do
    {
      'label' => [],
      'tag' => [],
      'jobs' => 2,
      'max-memory-mib' => nil,
      'max-shm-mib' => nil,
      'max-cpus' => nil,
      'memory-reserve-mib' => nil,
      'shm-reserve-mib' => nil,
      'cpu-reserve' => nil,
      'memory-overcommit' => nil,
      'shm-overcommit' => nil,
      'cpu-overcommit' => nil,
      'resource-refresh-interval' => nil,
      'status-interval' => nil,
      'verbose' => false,
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

  before do
    allow(TestRunner::TestState).to receive(:with_lock).and_yield
  end

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
      state_dir: File.join(ENV['TMPDIR'] || '/tmp', 'os-test-runner'),
      jobs: 2,
      jobs_auto: false,
      max_memory_mib: nil,
      max_shm_mib: nil,
      max_cpus: nil,
      memory_reserve_mib: nil,
      shm_reserve_mib: nil,
      cpu_reserve: nil,
      memory_overcommit: nil,
      shm_overcommit: nil,
      cpu_overcommit: nil,
      resource_refresh_interval: nil,
      status_interval: nil,
      verbose: false,
      default_timeout: 60,
      stop_on_failure: false,
      destructive: true,
      recreate_disks: false,
      system: 'x86_64-linux',
      test_config_path: nil,
      repo_root: REPO_ROOT
    )
  end

  it 'resolves automatic jobs to the selected test count' do
    test = build_test(
      scripts: {
        'smoke' => {},
        'full' => {}
      }
    )
    other_test = build_test(path: 'suite/other', name: 'other')
    scripts = [
      test.test_scripts['smoke'],
      test.test_scripts['full'],
      other_test.test_scripts['default']
    ]
    executor = instance_double(TestRunner::Executor, run: [])
    stub_test_script_list(scripts)
    allow(TestRunner::Executor).to receive(:new).and_return(executor)

    described_class.new({}, opts.merge('jobs' => 'auto'), []).test

    expect(TestRunner::Executor).to have_received(:new).with(
      scripts,
      hash_including(jobs: 2, jobs_auto: true)
    )
  end

  it 'passes suite status and verbose options to the executor' do
    scripts = [instance_double(TestRunner::TestScript, path: 'suite/a')]
    executor = instance_double(TestRunner::Executor, run: [])
    stub_test_script_list(scripts)
    allow(TestRunner::Executor).to receive(:new).and_return(executor)

    described_class.new({}, opts.merge('status-interval' => '60', 'verbose' => true), []).test

    expect(TestRunner::Executor).to have_received(:new).with(
      scripts,
      hash_including(status_interval: '60', verbose: true)
    )
  end

  [false, true].each do |fresh|
    it "starts debug with fresh=#{fresh}" do
      test = build_test(name: 'debug-test')
      script = test.test_scripts['default']
      list = instance_double(TestRunner::TestScriptList, by_path: script)
      evaluator = instance_double(TestRunner::TestEvaluator, interactive: nil)
      allow(TestRunner::TestScriptList).to receive(:new).and_return(list)
      allow(TestRunner::TestEvaluator).to receive(:new).and_return(evaluator)

      described_class.new({}, opts.merge('fresh' => fresh), ['suite/example']).debug
      state_root = File.join(ENV['TMPDIR'] || '/tmp', 'os-test-runner')

      expect(TestRunner::TestEvaluator).to have_received(:new).with(
        test,
        [script],
        system: 'x86_64-linux',
        test_config_path: nil,
        repo_root: REPO_ROOT,
        state_dir: TestRunner::TestState.directory(state_root, test),
        sock_dir: File.join(state_root, 'socks'),
        default_timeout: 60,
        destructive: false,
        recreate_disks: fresh
      )
      expect(evaluator).to have_received(:interactive)
    end
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
    list = instance_double(TestRunner::TestScriptList)
    allow(TestRunner::TestScriptList).to receive(:new).and_return(list)
    allow(list).to receive(:matching).with('suite/*').and_return([matching, nonmatching])

    filtered = described_class.new({}, opts.merge('label' => ['tier=1'], 'tag' => ['smoke']), []).send(
      :select_test_scripts,
      'suite/*'
    )

    expect(filtered).to eq([matching])
  end

  it 'passes one immutable source to discovery and execution' do
    scripts = [instance_double(TestRunner::TestScript, path: 'suite/a')]
    executor = instance_double(TestRunner::Executor, run: [])
    source = instance_double(
      TestRunner::RepositorySource,
      path: '/nix/store/stable-source',
      resolve_path: '/nix/store/stable-source/tests/config.nix'
    )
    stub_test_script_list(scripts)
    allow(TestRunner::Executor).to receive(:new).and_return(executor)

    command.instance_variable_set(:@repository_source, source)
    described_class.new(
      {},
      opts.merge('test-config' => 'tests/config.nix'),
      []
    ).tap { |cmd| cmd.instance_variable_set(:@repository_source, source) }.test

    expect(TestRunner::TestScriptList).to have_received(:new).with(
      system: 'x86_64-linux',
      test_config_path: '/nix/store/stable-source/tests/config.nix',
      repo_root: '/nix/store/stable-source'
    )
    expect(TestRunner::Executor).to have_received(:new).with(
      scripts,
      hash_including(
        test_config_path: '/nix/store/stable-source/tests/config.nix',
        repo_root: '/nix/store/stable-source'
      )
    )
  end

  it 'exports the immutable source to test definitions and restores the environment' do
    source = instance_double(TestRunner::RepositorySource, path: '/nix/store/stable-source')
    original_root = ENV.fetch('TEST_RUNNER_REPO_ROOT', nil)
    ENV['TEST_RUNNER_REPO_ROOT'] = '/work/original-source'
    allow(TestRunner::RepositorySource).to receive(:open).and_yield(source)

    described_class.new({}, opts.merge('system' => 'aarch64-linux'), []).send(:with_repository_source) do
      expect(ENV.fetch('TEST_RUNNER_REPO_ROOT')).to eq('/nix/store/stable-source')
    end

    expect(ENV.fetch('TEST_RUNNER_REPO_ROOT')).to eq('/work/original-source')
    expect(TestRunner::RepositorySource).to have_received(:open).with(
      original_path: '/work/original-source'
    )
  ensure
    if original_root.nil?
      ENV.delete('TEST_RUNNER_REPO_ROOT')
    else
      ENV['TEST_RUNNER_REPO_ROOT'] = original_root
    end
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
    list = instance_double(TestRunner::TestScriptList)
    allow(TestRunner::TestScriptList).to receive(:new).and_return(list)
    allow(list).to receive(:matching).with('suite/*').and_return([matching, nonmatching])

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

  it 'defaults the state dir under /tmp when neither state-dir nor TMPDIR is provided' do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('TMPDIR').and_return(nil)

    expect(command.send(:state_dir)).to eq('/tmp/os-test-runner')
  end

  it 'defaults the state dir under the configured TMPDIR when state-dir is not provided' do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('TMPDIR').and_return('/var/tmp/unit-test-state')

    expect(command.send(:state_dir)).to eq('/var/tmp/unit-test-state/os-test-runner')
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

  it 'constructs no executor before full preparation and injects the startup pool' do
    test = build_test
    scripts = [build_test_script(test)]
    stub_test_script_list(scripts)
    pool = instance_double(TestRunner::ResourcePool, refresh_capacity: false)
    preparation = instance_double(TestRunner::Prebuild)
    executor = instance_double(TestRunner::Executor, run: [])
    config = instance_double(TestRunner::TestConfig)
    events = []
    allow(TestRunner::ResourcePool).to receive(:from_options).and_return(pool)
    allow(TestRunner::Prebuild).to receive(:new) do |*_args, **options|
      expect(options.fetch(:resource_pool)).to equal(pool)
      preparation
    end
    allow(preparation).to receive(:open) do |&runtime|
      events << :preparation_complete
      results = runtime.call(test => config)
      events << :runtime_cleanup_complete
      results
    end
    allow(TestRunner::Executor).to receive(:new) do |*_args, **options|
      expect(events).to eq([:preparation_complete])
      expect(options.fetch(:resource_pool)).to equal(pool)
      expect(options.fetch(:prepared_configs)).to eq(test => config)
      executor
    end
    described_class.new({}, opts.merge('prebuild' => true), []).test
    expect(pool).to have_received(:refresh_capacity).once
    expect(events).to eq(%i[preparation_complete runtime_cleanup_complete])
  end

  it 'never constructs an executor when preparation fails, even for expected failures' do
    test = build_test(expect_failure: true)
    stub_test_script_list([build_test_script(test)])
    preparation = instance_double(TestRunner::Prebuild)
    allow(TestRunner::Prebuild).to receive(:new).and_return(preparation)
    allow(preparation).to receive(:open).and_raise('preparation failed')
    allow(TestRunner::Executor).to receive(:new)
    expect do
      described_class.new({}, opts.merge('prebuild' => true), []).test
    end.to raise_error('preparation failed')
    expect(TestRunner::Executor).not_to have_received(:new)
  end

  it 'rejects a non-positive preparation estimate even when prebuild is disabled' do
    expect do
      described_class.new({}, opts.merge('prebuild-memory-per-job-mib' => 0), []).test
    end.to raise_error(ArgumentError, /must be positive/)
  end

  describe 'prepared machine validation barrier' do
    let(:machine_config) do
      {
        'spin' => 'vpsadminos', 'qemu' => '/qemu', 'virtiofsd' => '/virtiofsd',
        'kernel' => '/kernel', 'initrd' => '/initrd', 'toplevel' => '/system', 'squashfs' => '/root.squashfs',
        'memory' => 1024, 'cpus' => 2, 'cpu' => { 'cores' => 2, 'threads' => 1, 'sockets' => 1 },
        'disks' => [{ 'device' => 'data.img', 'type' => 'file', 'size' => '1G' }],
        'networks' => [
          { 'type' => 'user' },
          { 'type' => 'socket', 'mac' => '52:54:00:00:00:11', 'mcast' => { 'port' => 'test' } }
        ]
      }
    end

    [
      [{ 'networks' => [{ 'type' => 'bridge', 'opts' => {} }] }, /link/],
      [{ 'networks' => [{ 'type' => 'user', 'opts' => {} }] }, /network/],
      [{ 'testShells' => 0 }, /testShells must be an integer/],
      [{ 'testShellTransport' => 'invalid' }, /unsupported test shell transport/],
      [{ 'testShells' => 2, 'shells' => %w[first second] }, /testShells must be greater than/],
      [{ 'spin' => 'nixos', 'rootDisk' => {}, 'diskImage' => '/root.img' }, /cannot be used together/]
    ].each do |invalid_fields, error_message|
      it "rejects a later malformed machine before Executor or fresh disk reset: #{invalid_fields.inspect}" do
        with_tmpdir do |dir|
          test = build_test(expect_failure: true)
          script = build_test_script(test)
          stub_test_script_list([script])
          invalid = machine_config.merge(invalid_fields)
          config_data = {
            'machines' => { 'first' => machine_config, 'second' => invalid },
            'testScripts' => { 'default' => { 'script' => '' } }
          }
          json_path = '/nix/store/prepared-invalid-later-machine.json'
          root = File.join(dir, 'preparation.root')
          nix = instance_double(TestRunner::NixCli, local_max_jobs: 1)
          pool = instance_double(TestRunner::ResourcePool, prebuild_memory_mib: 16_384, prebuild_memory_status: 'test')
          gc_root = instance_double(TestRunner::GcRoot)
          machine = instance_double(OsVm::VpsadminosMachine, destroy_disks: nil)
          marker = File.join(dir, 'retained-disk.img')
          File.write(marker, 'retained data')
          allow(TestRunner::ResourcePool).to receive(:from_options).and_return(pool)
          allow(TestRunner::NixCli).to receive(:new).and_return(nix)
          allow(TestRunner::GcRoot).to receive(:new).and_return(gc_root)
          allow(gc_root).to receive(:open).and_yield(root)
          allow(nix).to receive(:build_test_batch) do |requests, output, **_options|
            File.write(output, JSON.generate([{ id: requests.first.fetch(:id), json: json_path }]))
          end
          allow(File).to receive(:file?).and_call_original
          allow(File).to receive(:file?).with(json_path).and_return(true)
          allow(File).to receive(:read).and_call_original
          allow(File).to receive(:read).with(json_path).and_return(JSON.generate(config_data))
          allow(TestRunner::Executor).to receive(:new).and_raise('Executor entered before validation')
          allow(OsVm::VpsadminosMachine).to receive(:new).and_return(machine)
          allow(OsVm::NixosMachine).to receive(:new)
          allow(OsVm::MacAddressGenerator).to receive(:next_mac).and_call_original
          allow(OsVm::MacAddressGenerator).to receive(:register_mac).and_call_original
          allow(OsVm::PortReservation).to receive(:get_port).and_call_original

          expect do
            described_class.new({}, opts.merge('prebuild' => true, 'fresh' => true, 'state-dir' => dir), []).test
          end.to raise_error(RuntimeError, /Test preparation failed:.*#{error_message.source}/)

          expect(TestRunner::Executor).not_to have_received(:new)
          expect(OsVm::VpsadminosMachine).not_to have_received(:new)
          expect(OsVm::NixosMachine).not_to have_received(:new)
          expect(machine).not_to have_received(:destroy_disks)
          expect(OsVm::MacAddressGenerator).not_to have_received(:next_mac)
          expect(OsVm::MacAddressGenerator).not_to have_received(:register_mac)
          expect(OsVm::PortReservation).not_to have_received(:get_port)
          expect(File.read(marker)).to eq('retained data')
          expect(Dir.glob(File.join(dir, '**/test-result.txt'))).to be_empty
        end
      end
    end
  end
end
