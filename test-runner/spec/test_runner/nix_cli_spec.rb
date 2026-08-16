# frozen_string_literal: true

require 'rbconfig'
require 'spec_helper'

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
    status = instance_double(Process::Status, success?: false, exitstatus: 1)
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
end
