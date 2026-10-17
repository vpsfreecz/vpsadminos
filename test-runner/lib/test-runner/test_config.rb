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

    def self.load(test, config_path:)
      tc = new(test, config_path:)
      tc.load
      tc
    end

    # @return [Test]
    attr_reader :test, :config_path

    # @param test [Test]
    # @param config_path [String]
    def initialize(test, config_path:, system: NixCli::DEFAULT_SYSTEM, test_config_path: nil, repo_root: nil)
      @test = test
      @nix_options = { system:, test_config_path:, repo_root: }
      @config_path = config_path
      @config = {}
    end

    def build
      FileUtils.mkdir_p(File.dirname(config_path))
      NixCli.new(**@nix_options).build_test_json(test.path, config_path, test_args: test.test_args)
      load
    end

    def load
      @config = JSON.parse(File.read(config_path))
    end

    def validate!(scripts)
      unless @config.is_a?(Hash) && @config['machines'].is_a?(Hash) && @config['testScripts'].is_a?(Hash)
        raise ArgumentError, "Invalid prepared configuration for #{test.path}"
      end

      scripts.each do |script|
        entry = @config['testScripts'][script.name]
        next if entry.is_a?(Hash) && entry['script'].is_a?(String)

        raise ArgumentError, "Missing or invalid prepared script #{script.path}"
      end

      @config['machines'].each_value do |machine|
        unless machine.is_a?(Hash) && machine['memory'].is_a?(Integer) && machine['memory'] > 0 &&
               machine['cpus'].is_a?(Integer) && machine['cpus'] > 0
          raise ArgumentError, "Invalid prepared machine for #{test.path}"
        end

        OsVm::MachineConfig.validate_config!(machine)
      end

      self
    end

    def [](key)
      @config[key]
    end

    def dig(*keys)
      @config.dig(*keys)
    end
  end
end
