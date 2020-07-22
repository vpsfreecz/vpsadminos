require 'json'
require 'fileutils'

module TestRunner
  class TestConfig
    # @param test [Test]
    def self.build(test)
      tc = new(test)
      tc.build
      tc
    end

    attr_reader :test

    # @param test [Test]
    def initialize(test)
      @test = test
      @config = {}
    end

    def build
      FileUtils.mkdir_p('result/tests')
      pid = spawn("nix-build --attr json --out-link #{config_path} ./tests/suite/#{test.path}.nix")
      Process.wait(pid)
      fail 'nix-build failed' if $?.exitstatus != 0
      @config = JSON.parse(File.read(config_path), symbolize_names: true)
    end

    def [](key)
      @config[key]
    end

    protected
    def config_path
      "result/tests/#{test.name}-config.json"
    end
  end
end
