require 'json'
require 'fileutils'

module TestRunner
  class TestConfig
    # @param test [Test]
    # @param config_path [String]
    def self.build(test, config_path:, system: NixCli::DEFAULT_SYSTEM, test_config_path: nil, repo_root: nil)
      tc = new(test, system:, test_config_path:, repo_root:, config_path:)
      tc.build
      tc
    end

    # @return [Test]
    attr_reader :test, :config_path

    # @param test [Test]
    # @param config_path [String]
    def initialize(test, config_path:, system: NixCli::DEFAULT_SYSTEM, test_config_path: nil, repo_root: nil)
      @test = test
      @nix = NixCli.new(system:, test_config_path:, repo_root:)
      @config_path = config_path
      @config = {}
    end

    def build
      FileUtils.mkdir_p(File.dirname(config_path))
      @nix.build_test_json(test.path, config_path, test_args: test.test_args)
      @config = JSON.parse(File.read(config_path))
    end

    def [](key)
      @config[key]
    end

    def dig(*keys)
      @config.dig(*keys)
    end
  end
end
