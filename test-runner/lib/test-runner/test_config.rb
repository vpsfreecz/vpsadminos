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
      cmd = [
        'nix-build',
        '--attr', 'json',
        '--out-link', config_path,
      ]

      if test.template?
        cmd << '--argstr' << 'templateArgsInJson' << test.args.to_json
      end

      cmd << "./tests/suite/#{test.file_path}"

      FileUtils.mkdir_p('result/tests')
      pid = spawn(*cmd)
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
