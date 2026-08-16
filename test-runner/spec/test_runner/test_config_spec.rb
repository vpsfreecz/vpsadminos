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
end
