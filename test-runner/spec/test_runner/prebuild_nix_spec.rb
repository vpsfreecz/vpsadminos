# frozen_string_literal: true

require 'spec_helper'
require 'open3'

RSpec.describe TestRunner::Prebuild do
  def write_repository(dir, native:, framework:)
    nixpkgs = ENV.fetch('TEST_RUNNER_NIXPKGS_PATH')
    tests_dir = File.join(dir, 'tests/suite')
    FileUtils.mkdir_p(tests_dir)
    if native
      File.symlink(nixpkgs, File.join(dir, 'nixpkgs'))
      library_dir = File.join(dir, 'test-runner/nix')
      FileUtils.mkdir_p(library_dir)
      FileUtils.cp(File.join(REPO_ROOT, 'test-runner/nix/lib.nix'), library_dir)
      File.write(File.join(tests_dir, 'registered.nix'), <<~NIX)
        { pkgs, system, testArgs, testConfig, configuration, ... }:
        let p = import pkgs { inherit system; }; in {
          json = p.writeText "native.json" (builtins.toJSON {
            args = testArgs;
            cfg = testConfig;
            host = configuration;
          });
        }
      NIX
    else
      # A matching suite pathname alone must not activate native imports.
      File.write(File.join(tests_dir, 'registered.nix'), 'throw "external suite must use registered export"')
    end
    File.write(File.join(dir, 'flake.nix'), <<~NIX)
      {
        outputs = { self }: let
          p = import #{nixpkgs} { system = "x86_64-linux"; };
          testsFor = cfg: host: {
            registered = p.writeText "registered.json" (builtins.toJSON { inherit cfg host; args.value = "registered"; });
            "template@a" = p.writeText "template-a.json" (builtins.toJSON { inherit cfg host; version = "a"; });
            unselected = p.writeText "unselected.json" "unselected";
          };
        in {
          tests.x86_64-linux = testsFor {} null;
          testsMeta.x86_64-linux = {};
          #{if framework
              'lib.testFramework = { mkTests = args: testsFor args.testConfig args.configuration; mkTestsMeta = args: {}; };'
            end}
        };
      }
    NIX
  end

  def evaluate_batch(dir, requests, env: {}, test_config_path: nil)
    helper = File.join(REPO_ROOT, 'test-runner/nix/evaluate-tests.nix')
    expression = <<~NIX
      let
        common = { repoRoot = #{dir}; #{"testConfigPath = #{test_config_path};" if test_config_path} };
        requests = builtins.fromJSON #{JSON.generate(JSON.generate(requests))};
        batch = import #{helper} (common // { mode = "testBatch"; selectedTestsJson = builtins.toJSON requests; });
        single = request: import #{helper} (common // {
          mode = "testJson"; testPath = request.path;
          testArgsJson = builtins.toJSON (request.testArgs or {});
        });
      in {
        manifest = builtins.fromJSON (builtins.unsafeDiscardStringContext batch.text);
        references = builtins.attrNames (builtins.getContext batch.text);
        singles = map (request: { json = toString (single request); data = builtins.fromJSON (builtins.unsafeDiscardStringContext (single request).text); }) requests;
      }
    NIX
    output, status = Open3.capture2(env, 'nix-instantiate', '--eval', '--strict', '--json', '--expr', expression)
    raise "Nix selection evaluation failed (#{status.exitstatus})" unless status.success?

    JSON.parse(output)
  end

  it 'preserves external registered exports and templates without a native helper or framework' do
    with_tmpdir do |dir|
      write_repository(dir, native: false, framework: false)
      result = evaluate_batch(dir, [{ id: 'a', path: 'registered' }, { id: 'b', path: 'template@a' }])
      expect(result.fetch('manifest').map { |entry| entry.fetch('json') }).to eq(
        result.fetch('singles').map { |entry| entry.fetch('json') }
      )
      expect(result.fetch('singles').first.fetch('data').fetch('args')).to eq('value' => 'registered')
      expect(result.fetch('singles').last.fetch('data').fetch('version')).to eq('a')
      expect(result.fetch('references').size).to eq(2)
      expect(result.fetch('references').join).not_to include('unselected')
    end
  end

  it 'keeps native arguments, test configuration and host configuration in the exact selected closure' do
    with_tmpdir do |dir|
      write_repository(dir, native: true, framework: true)
      config = File.join(dir, 'config.nix')
      File.write(config, '{ fixture = "host-override"; }')
      result = evaluate_batch(
        dir, [{ id: 'a', path: 'registered', testArgs: { value: 'selected-argument' } }, { id: 'b', path: 'template@a' }],
        env: { 'VPSADMINOS_CONFIG' => config }
      )
      expect(result.fetch('singles').first.fetch('data')).to include(
        'args' => { 'value' => 'selected-argument' }, 'host' => { 'fixture' => 'host-override' }
      )
      expect(result.fetch('singles').last.fetch('data').fetch('host')).to eq('fixture' => 'host-override')
      expect(result.fetch('manifest').map { |entry| entry.fetch('json') }).to eq(
        result.fetch('singles').map { |entry| entry.fetch('json') }
      )
      expect(result.fetch('references').size).to eq(2)
    end
  end

  it 'preserves explicit test configuration for native tests and registered templates' do
    with_tmpdir do |dir|
      write_repository(dir, native: true, framework: true)
      config = File.join(dir, 'test-config.nix')
      File.write(config, '{ fixture = "test-override"; }')
      result = evaluate_batch(
        dir, [{ id: 'a', path: 'registered' }, { id: 'b', path: 'template@a' }], test_config_path: config
      )
      result.fetch('singles').each do |entry|
        expect(entry.fetch('data').fetch('cfg')).to eq('fixture' => 'test-override')
      end
      expect(result.fetch('manifest').map { |entry| entry.fetch('json') }).to eq(
        result.fetch('singles').map { |entry| entry.fetch('json') }
      )
    end
  end
end
