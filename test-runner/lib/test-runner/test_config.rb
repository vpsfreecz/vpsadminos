require 'json'
require 'fileutils'

module TestRunner
  class TestConfig
    # @param test [Test]
    def self.build(test, system: NixCli::DEFAULT_SYSTEM, test_config_path: nil)
      tc = new(test, system:, test_config_path:)
      tc.build
      tc
    end

    # @return [Test]
    attr_reader :test

    # @param test [Test]
    def initialize(test, system: NixCli::DEFAULT_SYSTEM, test_config_path: nil)
      @test = test
      @nix = NixCli.new(system:, test_config_path:)
      @config = {}
    end

    def build
      FileUtils.mkdir_p('result/tests')
      @nix.build_test_json(test.path, config_path)
      @config = JSON.parse(File.read(config_path))
    end

    def [](key)
      @config[key]
    end

    def dig(*keys)
      @config.dig(*keys)
    end

    protected

    def config_path
      "result/tests/#{test.name}-config.json"
    end
  end
end
