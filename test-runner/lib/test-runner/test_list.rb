require 'json'

module TestRunner
  class TestList
    def initialize(system: NixCli::DEFAULT_SYSTEM, test_config_path: nil, repo_root: nil)
      @nix = NixCli.new(system:, test_config_path:, repo_root:)
    end

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

    def extract_all
      @nix.eval_tests_meta_all
    end

    def extract_one(path)
      @nix.eval_test_meta(path)
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
        test_script_jobs: data['testScriptJobs'],
        resources: data['resources'],
        tags: data['tags'],
        labels: data['labels'],
        test_scripts: data['testScripts']
      )
    end
  end
end
