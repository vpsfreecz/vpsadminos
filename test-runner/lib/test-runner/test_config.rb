require 'json'
require 'fileutils'
require 'open3'

module TestRunner
  class TestConfig
    # @param test [Test]
    def self.build(test)
      tc = new(test)
      tc.build
      tc
    end

    # @return [Test]
    attr_reader :test

    # @param test [Test]
    def initialize(test)
      @test = test
      @config = {}
    end

    def build
      FileUtils.mkdir_p('result/tests')
      ref = ".#tests.#{nix_system}.\"#{nix_quote_attr(test.path)}\""

      cmd = [
        'nix', 'build',
        '--impure',
        '--out-link', config_path,
        ref
      ]

      pid = spawn(*cmd)
      Process.wait(pid)
      raise 'nix build failed' if $?.exitstatus != 0

      @config = JSON.parse(File.read(config_path))
    end

    def [](key)
      @config[key]
    end

    protected

    def nix_system
      @nix_system ||= begin
        out, status = Open3.capture2(
          'nix',
          'eval',
          '--raw',
          '--impure',
          '--expr',
          'builtins.currentSystem'
        )
        raise "nix eval builtins.currentSystem failed (#{status.exitstatus})" unless status.success?

        out.strip
      end
    end

    def nix_quote_attr(s)
      s.to_s.gsub('\\', '\\\\').gsub('"', '\\"')
    end

    def config_path
      "result/tests/#{test.name}-config.json"
    end
  end
end
