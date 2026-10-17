# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TestRunner::TestConfig do
  it 'builds the config file, loads it, and exposes [] and dig' do
    with_tmpdir do |dir|
      input_test_args = { 'distributions' => %w[debian-stable alpine-latest] }
      test = build_test(test_args: input_test_args)
      config_path = File.join(dir, 'nested', 'config.json')
      nix = instance_double(TestRunner::NixCli)
      allow(TestRunner::NixCli).to receive(:new).and_return(nix)
      allow(nix).to receive(:build_test_json) do |_path, out, test_args:|
        expect(test_args).to eq(test.test_args)
        File.write(out, JSON.dump('framework' => { 'testConfig' => { 'foo' => 'bar' } }))
      end

      config = described_class.build(test, config_path:)

      expect(File.exist?(config_path)).to be(true)
      expect(nix).to have_received(:build_test_json).with(
        'suite/example',
        config_path,
        test_args: test.test_args
      )
      expect(config['framework']).to eq('testConfig' => { 'foo' => 'bar' })
      expect(config.dig('framework', 'testConfig', 'foo')).to eq('bar')
    end
  end

  it 'loads and validates a prepared config without creating a Nix client' do
    with_tmpdir do |dir|
      test = build_test
      path = File.join(dir, 'config.json')
      File.write(path, JSON.generate('machines' => {}, 'testScripts' => { 'default' => { 'script' => '' } }))
      allow(TestRunner::NixCli).to receive(:new).and_call_original
      cfg = described_class.load(test, config_path: path)
      expect(cfg.validate!(test.test_scripts.values)).to equal(cfg)
      expect(TestRunner::NixCli).not_to have_received(:new)
    end
  end

  it 'rejects an invalid prepared machine before runtime can reset any disk' do
    with_tmpdir do |dir|
      path = File.join(dir, 'config.json')
      File.write(path, JSON.generate('machines' => { 'bad' => {} }, 'testScripts' => {}))
      cfg = described_class.load(build_test, config_path: path)
      expect { cfg.validate!([]) }.to raise_error(ArgumentError, /Invalid prepared machine/)
    end
  end
end
