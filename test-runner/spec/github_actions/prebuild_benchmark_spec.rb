# frozen_string_literal: true

require 'spec_helper'
require 'yaml'
require 'rbconfig'
require_relative '../../../.github/workflows/scripts/prebuild_benchmark'

RSpec.describe PrebuildBenchmark do
  it 'compares normal full CLI commands with only the mode and isolated state changed' do
    a = described_class.command('--no-prebuild', '/state/A-state')
    b = described_class.command('--prebuild', '/state/B-state')
    expect(a.first(2)).to eq(['./test-runner.sh', 'test'])
    expect(a.values_at(2, 11)).to eq(['--no-prebuild', '/state/A-state'])
    expect(a.each_index.reject { |i| a[i] == b[i] }).to eq([2, 11])
    expect(a).to include('--jobs', 'auto', '--fresh', '-t', 'ci', 'tests/test-configs/ci.nix')
    expect(a).not_to include('--max-cpus', '--max-memory-mib', '--cores', '--stop-on-failure')
  end

  it 'starts a separate Ruby child without development Bundler startup or inherited bookkeeping' do
    with_tmpdir do |dir|
      setup = File.join(dir, 'development_setup.rb')
      File.write(setup, "abort 'development Bundler startup leaked'\n")
      original = Bundler.original_env.merge(
        'BUNDLER_SETUP' => setup, 'BUNDLE_GEMFILE' => File.join(dir, 'Gemfile'),
        'RUBYOPT' => '-rbundler/setup', 'NIX_BUILD_CORES' => '0',
        'TEST_RUNNER_STATE_DIR' => '/benchmark/state', 'VPSADMINOS_CONFIG' => ''
      )
      stub_const('Bundler::ORIGINAL_ENV', original)
      environment = described_class.cli_environment
      code = "puts JSON.generate(ENV.to_h.slice('BUNDLER_SETUP', 'BUNDLE_GEMFILE', 'NIX_BUILD_CORES', 'TEST_RUNNER_STATE_DIR', 'VPSADMINOS_CONFIG'))"
      output, status = Open3.capture2e(environment, RbConfig.ruby, '-rjson', '-e', code, unsetenv_others: true)
      expect(status.exitstatus).to eq(0), output
      expect(JSON.parse(output)).to eq('NIX_BUILD_CORES' => '0', 'TEST_RUNNER_STATE_DIR' => '/benchmark/state', 'VPSADMINOS_CONFIG' => '')
      expect(environment.keys.grep(/\ABUNDLER_ORIG_/)).to be_empty
      expect(ENV.fetch('BUNDLER_SETUP')).not_to eq(setup)
    end
  end

  it 'captures exact selected scripts, completed work and reported executor time' do
    log = <<~LOG
      The following test scripts will be run:
        z/test#b
        a/test

      [2026-10-19 15:00:00 +0200] Running 2 scripts of 2 tests, at most 2 tests at a time (auto)
      [2026-10-19 15:00:00 +0200] Resource limits: memory=0.00 GiB/64.00 GiB, shm=0.00 GiB/32.00 GiB, cpus=0/48.0, running=0
      [2026-10-19 15:01:00 +0200] Run 2 test scripts of 2 tests in 60.25 seconds
      [2026-10-19 15:01:00 +0200] Unexpectedly failed test scripts:
      [2026-10-19 15:01:00 +0200]   z/test#b

    LOG
    result = described_class.parse_log(log)
    expect(result).to include('scripts' => ['a/test', 'z/test#b'], 'completed_scripts' => 2,
                              'completed_tests' => 2, 'executor_reported_seconds' => 60.25)
    expect(result['selection_digest']).to eq(Digest::SHA256.hexdigest(JSON.generate(['a/test', 'z/test#b'])))
    expect(result['unexpected_failed_scripts']).to eq(['z/test#b'])
    expect(result['initial_resource_limits']).to eq('memory=0.00 GiB/64.00 GiB, shm=0.00 GiB/32.00 GiB, cpus=0/48.0, running=0')
    expect(described_class.phase_marker(log.lines[4])).to eq('executor_start')
  end

  def completed_leg(seconds)
    {
      'wall_seconds' => seconds, 'selection_digest' => 'selected',
      'completed_scripts' => 335, 'completed_tests' => 127,
      'owned_processes_remaining' => [], 'image_builds' => [], 'oom_delta' => 0,
      'resource_identity' => { 'cpus' => 32 }, 'outcomes' => { 'test' => 'expected_success' }, 'exit_status' => 0,
      'initial_resource_limits' => 'memory=0.00 GiB/64.00 GiB, shm=0.00 GiB/32.00 GiB, cpus=0/48.0, running=0'
    }
  end

  it 'reports exploratory delta, ratio and percentage for matched completed work' do
    report = described_class.compare([completed_leg(100), completed_leg(110)], 'selected')
    expect(report).to include('complete' => true, 'comparable_work' => true, 'delta_seconds' => 10, 'ratio' => 1.1)
    expect(report['percent_change']).to be_within(0.0001).of(10)
  end

  it 'retains timings but qualifies unequal failures and resource drift' do
    a = completed_leg(100)
    b = completed_leg(125).merge('outcomes' => { 'test' => 'unexpected_failure' }, 'exit_status' => 1,
                                 'resource_identity' => { 'cpus' => 16 })
    report = described_class.compare([a, b], 'selected')
    expect(report).to include('comparable_work' => false, 'ratio' => 1.25, 'both_successful' => false)
  end

  it 'qualifies different failed scripts or retries even when group outcomes match' do
    a = completed_leg(100).merge('unexpected_failed_scripts' => ['test#one'], 'retries' => [])
    b = a.merge('unexpected_failed_scripts' => ['test#two'])
    expect(described_class.compare([a, b], 'selected')['comparable_work']).to be(false)
    b = a.merge('retries' => [['test', ['#one'], '2']])
    expect(described_class.compare([a, b], 'selected')['comparable_work']).to be(false)
    b = a.merge('resource_identity_changed' => true)
    expect(described_class.compare([a, b], 'selected')['comparable_work']).to be(false)
  end

  it 'qualifies different initial executor ceilings despite identical assigned host resources' do
    a = completed_leg(100)
    b = completed_leg(125).merge('initial_resource_limits' => 'memory=0.00 GiB/48.00 GiB, shm=0.00 GiB/24.00 GiB, cpus=0/48.0, running=0')
    expect(described_class.compare([a, b], 'selected')).to include('complete' => true, 'comparable_work' => false, 'ratio' => 1.25)
    expect(described_class.compare([a, b.merge('initial_resource_limits' => nil)], 'selected')['comparable_work']).to be(false)
  end

  it 'qualifies a transient runtime reduction while allowing a cleaned complete leg B' do
    with_tmpdir do |dir|
      run = described_class::Run.new(dir, dir)
      run.instance_variable_get(:@report)['selection_digest'] = 'selected'
      initial = completed_leg(100).fetch('initial_resource_limits')
      log = <<~LOG
        [2026-10-19 15:00:00 +0200] Resource limits: #{initial}
        [2026-10-19 15:00:15 +0200] Resource limits updated: memory=0.00 GiB/32.00 GiB, shm=0.00 GiB/16.00 GiB, cpus=0/48.0, running=0
        [2026-10-19 15:00:30 +0200] Resource limits updated: #{initial}
      LOG
      parsed = described_class.parse_log(log)
      expect(parsed['initial_resource_limits']).to eq(initial)
      expect(parsed['resource_limit_updates'].size).to eq(2)
      expect(parsed['resource_limit_updates'].first).to include('32.00 GiB')
      outcomes = (0...127).to_h { |i| [i.to_s, 'expected_success'] }
      a = completed_leg(100).merge('outcomes' => outcomes)
      b = completed_leg(110).merge('resource_limit_updates' => parsed['resource_limit_updates'], 'outcomes' => outcomes, 'kernel_failures' => [])
      expect(a['resource_identity']).to eq(b['resource_identity'])
      expect(a['initial_resource_limits']).to eq(b['initial_resource_limits'])
      expect(described_class.compare([a, b], 'selected')).to include('complete' => true, 'comparable_work' => false, 'delta_seconds' => 10)
      expect(run.send(:safe_to_continue?, b)).to be(true)
    end
  end

  it 'detects host image builds only in explicit runner-owned preparation logs' do
    with_tmpdir do |dir|
      state = File.join(dir, 'A-state')
      run = described_class::Run.new(dir, dir)
      host_paths = [
        File.join(dir, 'A.log'),
        File.join(state, 'os-test-system__install-123', 'test-runner.log'),
        File.join(state, 'os-test-system__install-123', 'attempt-1-123', 'test-runner.log'),
        File.join(state, 'prebuild-123', 'build.log')
      ]
      guest_path = File.join(state, 'os-test-system__install-123', 'installer-shell.log')
      [*host_paths, guest_path].each do |path|
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "building '/nix/store/fixture-image.drv'...\n")
      end
      builds = run.send(:host_image_builds, 'A', state)
      expect(builds.size).to eq(4)
      expect(builds).to match_array(host_paths.map { |path| "#{path}: building '/nix/store/fixture-image.drv'..." })
      expect(described_class.compare([completed_leg(100).merge('image_builds' => builds), completed_leg(110)], 'selected')['comparable_work']).to be(false)
    end
  end

  it 'checks actual Nix derivation inspection output before warming and still rejects uncached kernels' do
    expression = <<~NIX
      map (attrs: builtins.derivation ({
        system = builtins.currentSystem;
        builder = "/bin/false";
      } // attrs)) [
        { name = "benchmark-kernel-metadata"; pname = "ordinary-image"; }
        { name = "benchmark-uncached-kernel"; pname = "linux"; }
      ]
    NIX
    output, error, status = Open3.capture3('nix-instantiate', '--expr', expression)
    raise "Fixture instantiation failed: #{error}" unless status.success?

    ordinary, kernel = output.lines.map(&:strip)
    with_tmpdir do |dir|
      run = described_class::Run.new(REPO_ROOT, dir)
      allow(run).to receive(:capture).and_call_original
      allow(run).to receive(:snapshot).and_return(
        'available_memory_mib' => 8192, 'shm_available_mib' => 8192,
        'disk' => "Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 100 1 99 1% /\n", 'pressure' => {}
      )
      allow(run).to receive(:capture).with('nix-build', any_args).and_return("this derivation will be built:\n  #{ordinary}\n")
      expect { run.send(:preflight, [], REPO_ROOT, nil) }.not_to raise_error
      report = JSON.parse(File.read(File.join(dir, 'timings.json')))
      expect(report.fetch('preflight').fetch('missing_derivations')).to eq([ordinary])

      allow(run).to receive(:capture).with('nix-build', any_args).and_return("these derivations will be built:\n  #{ordinary}\n  #{kernel}\n")
      expect { run.send(:preflight, [], REPO_ROOT, nil) }.to raise_error(RuntimeError, /Uncached kernel compilation required: .*benchmark-uncached-kernel/)
    end
  end

  it 'accepts legacy flat derivation maps and fails closed on missing or malformed inspection entries' do
    with_tmpdir do |dir|
      run = described_class::Run.new(dir, dir)
      path = '/nix/store/fixture-image.drv'
      allow(run).to receive(:capture).with('nix', 'derivation', 'show', path).and_return(JSON.generate(path => { 'env' => { 'pname' => 'ordinary-image' } }))
      expect { run.send(:reject_uncached_kernels, [path]) }.not_to raise_error
      [{ 'version' => 4, 'derivations' => {} }, { path => 4 }].each do |response|
        allow(run).to receive(:capture).with('nix', 'derivation', 'show', path).and_return(JSON.generate(response))
        expect { run.send(:reject_uncached_kernels, [path]) }.to raise_error(RuntimeError, 'Invalid Nix derivation inspection response for missing builds')
      end
    end
  end

  it 'marks an interrupted pair incomplete while retaining the first leg elsewhere' do
    expect(described_class.compare([completed_leg(100)], 'selected')).to include('complete' => false)
    b = completed_leg(20).merge('signal' => 15, 'completed_tests' => nil)
    expect(described_class.compare([completed_leg(100), b], 'selected')).to include('complete' => false, 'comparable_work' => false)
  end

  it 'does not treat matching failed suites as a passing benchmark' do
    a = completed_leg(100).merge('exit_status' => 1)
    report = described_class.compare([a, a], 'selected')
    expect(report).to include('both_successful' => false)
    expect(report['qualification']).to include('Matching failures')
  end

  it 'uses one manual job with separate harness and exact product checkouts and always uploads evidence' do
    workflow = YAML.load_file(File.join(REPO_ROOT, '.github/workflows/ci.yml'))
    expect(workflow.fetch(true).keys).to eq(['workflow_dispatch'])
    expect(workflow.fetch('jobs').keys).to eq(['compare'])
    job = workflow.fetch('jobs').fetch('compare')
    expect(job).to include('runs-on' => 'self-hosted', 'timeout-minutes' => 1380)
    steps = job.fetch('steps')
    expect(steps[0].fetch('with')).to include('path' => 'benchmark-harness')
    expect(steps[1].fetch('with')).to include('path' => 'product', 'ref' => described_class::PRODUCT_SHA)
    upload = steps.find { |step| step['id'] == 'upload' }
    expect(upload['if']).to include('always()')
    expect(steps.last['if']).to eq('always()')
  end

  it 'records a failed complete CLI without treating its exit as permission to skip cleanup or leg B' do
    with_tmpdir do |dir|
      product = File.join(dir, 'product')
      root = File.join(dir, 'state')
      FileUtils.mkdir_p([product, root])
      scripts = Array.new(335) { |i| "test/#{i}" }.sort
      digest = Digest::SHA256.hexdigest(JSON.generate(scripts))
      run = described_class::Run.new(product, root)
      run.instance_variable_get(:@report)['selection_digest'] = digest
      allow(run).to receive(:snapshot).and_return('memory_events' => "oom_kill 0\n", 'cpus' => 4)
      code = <<~RUBY
        require 'fileutils'
        state = ARGV.fetch(0)
        puts 'The following test scripts will be run:'
        335.times { |i| puts "  test/\#{i}" }
        puts
        puts '[2026-10-19] Running 335 scripts of 127 tests, at most 127 tests at a time (auto)'
        installer = File.join(state, 'os-test-system__install-123')
        FileUtils.mkdir_p(installer)
        %w[installer-shell.log vm-console.log].each do |name|
          File.write(File.join(installer, name), "building '/nix/store/fixture-aliases.conf.drv'...\n")
        end
        127.times do |i|
          dir = File.join(state, i.to_s)
          FileUtils.mkdir_p(dir)
          File.write(File.join(dir, 'test-result.txt'), 'unexpected_failure')
        end
        puts '[2026-10-19] Run 335 test scripts of 127 tests in 0.25 seconds'
        exit 1
      RUBY
      allow(described_class).to receive(:command) do |_flag, state|
        [RbConfig.ruby, '-e', code, state]
      end
      leg = nil
      capture_stdout { leg = run.send(:measure, 'A', '--no-prebuild') }
      expect(leg).to include('exit_status' => 1, 'signal' => nil, 'selection_digest' => digest,
                             'completed_tests' => 127, 'completed_scripts' => 335, 'owned_processes_remaining' => [])
      expect(leg['wall_seconds']).to be > 0
      expect(leg['image_builds']).to be_empty
      expect(run.send(:safe_to_continue?, leg)).to be(true)
      expect(JSON.parse(File.read(File.join(root, 'timings.json')))['legs'].size).to eq(1)
      expect(run.send(:safe_to_continue?, leg.merge('forced_cleanup' => true))).to be(false)
    end
  end

  it 'reaps an interrupted owned CLI and retains its partial timing and signal' do
    with_tmpdir do |dir|
      product = File.join(dir, 'product')
      root = File.join(dir, 'state')
      FileUtils.mkdir_p([product, root])
      run = described_class::Run.new(product, root)
      allow(run).to receive(:snapshot).and_return('memory_events' => "oom_kill 0\n")
      code = '$stdout.sync = true; puts Process.pid; sleep 30'
      allow(described_class).to receive(:command).and_return([RbConfig.ruby, '-e', code])
      pid = nil
      allow(described_class).to receive(:phase_marker) do |line|
        pid = Integer(line)
        raise Interrupt, 'cancelled fixture'
      end
      capture_stdout do
        expect { run.send(:measure, 'A', '--no-prebuild') }.to raise_error(Interrupt, 'cancelled fixture')
      end
      leg = JSON.parse(File.read(File.join(root, 'timings.json')))['legs'].first
      expect(leg).to include('forced_cleanup' => true, 'signal' => Signal.list.fetch('TERM'), 'owned_processes_remaining' => [])
      expect(leg['wall_seconds']).to be > 0
      expect(leg['error']).to include('cancelled fixture')
      expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
      expect(run.send(:safe_to_continue?, leg)).to be(false)
    end
  end
end
