require 'json'
require 'open3'

module TestRunner
  class TestList
    # Return a list of all known tests
    # @return [Array<Test>]
    def all
      parse_many(extract_all)
    end

    # Filter through all tests, return those that the filter matched
    # @yieldparam [Test]
    # @return [Array<Test>]
    def filter(&)
      all.select(&)
    end

    # Return one test specified by path
    # @return [Test]
    def by_path(path)
      parse_one(path, extract_one(path))
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

    def extract_all
      cmd = ['nix', 'eval', '--json', '--impure', ".#testsMeta.#{nix_system}"]
      out, status = Open3.capture2(*cmd)
      raise "nix eval testsMeta failed (#{status.exitstatus})" unless status.success?

      out
    end

    def extract_one(path)
      ref = ".#testsMeta.#{nix_system}.\"#{nix_quote_attr(path)}\""
      cmd = ['nix', 'eval', '--json', '--impure', ref]
      out, status = Open3.capture2(*cmd)
      raise "nix eval testsMeta[#{path}] failed (#{status.exitstatus})" unless status.success?

      out
    end

    def parse_many(json)
      JSON.parse(json).map do |name, opts|
        create_test(name, opts)
      end
    end

    def parse_one(path, json)
      create_test(path, JSON.parse(json))
    end

    def create_test(path, data)
      Test.new(
        path: path,
        type: data['type'],
        template: data['template'],
        template_args: data['templateArgs'],
        test_args: data.fetch('testArgs', {}),
        name: data['name'],
        description: data['description'],
        attempts: data['attempts'],
        expect_failure: data['expectFailure'],
        tags: data['tags'],
        labels: data['labels'],
        test_scripts: data['testScripts']
      )
    end
  end
end
