# frozen_string_literal: true

require 'rbconfig'
require 'spec_helper'
require 'timeout'

RSpec.describe TestRunner::NixCli do
  it 'uses the default system when none is provided' do
    expect(described_class.new(system: '').system).to eq(described_class::DEFAULT_SYSTEM)
  end

  it 'normalizes repo_root and test_config_path' do
    cli = described_class.new(repo_root: '.', test_config_path: 'tests/config.nix')

    expect(cli.repo_root).to eq(File.expand_path('.'))
    expect(cli.test_config_path).to eq(File.expand_path('tests/config.nix'))
  end

  it 'builds eval_tests_meta_all commands' do
    cli = described_class.new(system: 'aarch64-linux')
    allow(cli).to receive(:capture_output).and_return('{}')

    cli.eval_tests_meta_all

    expect(cli).to have_received(:capture_output).with(
      'nix-instantiate',
      '--eval',
      '--strict',
      '--json',
      cli.send(:helper_file),
      '--arg',
      'repoRoot',
      cli.repo_root,
      '--argstr',
      'system',
      'aarch64-linux',
      '--argstr',
      'mode',
      'testsMetaAll'
    )
  end

  it 'builds eval_test_meta commands' do
    cli = described_class.new
    allow(cli).to receive(:capture_output).and_return('{}')

    cli.eval_test_meta('suite/example')

    expect(cli).to have_received(:capture_output) do |*args|
      expect(args).to include('testsMetaOne', 'suite/example')
    end
  end

  it 'builds test json commands' do
    cli = described_class.new
    allow(cli).to receive(:run!).and_return(nil)
    test_args = { 'distributions' => %w[debian-stable alpine-latest] }

    cli.build_test_json('suite/example', '/tmp/out', test_args:)

    expect(cli).to have_received(:run!) do |*args|
      expect(args).to include('nix-build', '--out-link', '/tmp/out', 'testJson', 'suite/example')
      expect(args).to include('--argstr', 'testArgsJson', JSON.generate(test_args))
    end
  end

  it 'raises on capture_output failures' do
    status = instance_double(Process::Status, success?: false, exitstatus: 1, signaled?: false)
    allow(Open3).to receive(:capture2).and_return(['', status])
    cli = described_class.new

    expect do
      cli.send(:capture_output, 'nix-instantiate', '--foo')
    end.to raise_error(RuntimeError, 'nix-instantiate --foo failed (1)')
  end

  it 'raises on run! failures' do
    cli = described_class.new

    expect do
      cli.send(:run!, RbConfig.ruby, '-e', 'exit 1')
    end.to raise_error(RuntimeError, /failed \(1\)/)
  end

  it 'limits only aggregate max-jobs and preserves CPU/cores settings' do
    cli = described_class.new
    allow(cli).to receive(:run!)
    selected = [{ id: 'one', path: 'suite/example', testArgs: { value: 'argument' } }]
    cli.build_test_batch(selected, '/tmp/root', max_jobs: 3, log_path: '/tmp/build.log')
    expect(cli).to have_received(:run!) do |*args, **options|
      expect(args).to include('testBatch', '--max-jobs', '3', 'selectedTestsJson', JSON.generate(selected))
      expect(args).not_to include('--cores', 'NIX_BUILD_CORES')
      expect(options).to eq(log_path: '/tmp/build.log')
    end
  end

  it 'reads effective inherited numeric and remote-only max-jobs without a CPU clamp' do
    cli = described_class.new
    [128, 0].each do |jobs|
      allow(cli).to receive(:capture_output).with('nix', 'config', 'show', '--json').and_return(
        JSON.generate('max-jobs' => { 'value' => jobs })
      )
      expect(cli.local_max_jobs).to eq(jobs)
    end
  end

  it 'resolves an inherited auto job setting' do
    cli = described_class.new
    allow(cli).to receive(:capture_output).and_return(JSON.generate('max-jobs' => { 'value' => 'auto' }))
    allow(TestRunner::ResourcePool).to receive(:detect_cpus).and_return(12)
    expect(cli.local_max_jobs).to eq(12)
  end

  it 'reports the actual terminating signal instead of a nil exit status' do
    with_tmpdir do |dir|
      log = File.join(dir, 'build.log')
      expect do
        described_class.new.send(:run!, RbConfig.ruby, '-e', 'Process.kill("KILL", Process.pid)', log_path: log)
      end.to raise_error(/failed \(signal 9 \(KILL\)\)/)
      expect(File.read(log)).to include('Preparation build failed (signal 9 (KILL))')
    end
  end

  it 'forwards cancellation to its owned build process group and reaps the client' do
    with_tmpdir do |dir|
      marker = File.join(dir, 'pid')
      log = File.join(dir, 'build.log')
      code = "File.write(#{marker.inspect}, Process.pid); sleep 30"
      worker = Thread.new do
        Thread.current.report_on_exception = false
        described_class.new.send(:run!, RbConfig.ruby, '-e', code, log_path: log)
      end
      pid = nil
      begin
        Timeout.timeout(3) { sleep(0.01) until File.file?(marker) }
        pid = Integer(File.read(marker))
        worker.raise(Interrupt)
        expect { Timeout.timeout(3) { worker.value } }.to raise_error(Interrupt)
        expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
        expect(File.read(log)).to include('Preparation interrupted by signal 2 (INT)')
      ensure
        begin
          Process.kill('KILL', -pid) if pid
        rescue Errno::ESRCH
          nil
        end
        worker.kill if worker.alive?
      end
    end
  end
end
