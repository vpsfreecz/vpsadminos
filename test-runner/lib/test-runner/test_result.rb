require 'json'

module TestRunner
  class TestResult
    # @return [Test]
    attr_reader :test

    # @return [Array<TestScriptResult>]
    attr_reader :script_results

    # @return [Boolean]
    attr_reader :success

    # @return [Float]
    attr_reader :elapsed_time

    # @return [String]
    attr_reader :state_dir

    def initialize(test, script_results, success, elapsed_time, state_dir)
      @test = test
      @script_results = script_results
      @success = success && script_results.all?(&:expected_result?)
      @elapsed_time = elapsed_time
      @state_dir = state_dir
    end

    def successful?
      @success
    end

    def failed?
      !@success
    end

    def expected_result?
      if test.expect_failure
        !@success
      else
        @success
      end
    end

    def unexpected_result?
      !expected_result?
    end

    def expected_to_succeed?
      !test.expect_failure
    end

    def expected_to_fail?
      test.expect_failure
    end

    # @return [Hash]
    def to_h
      {
        'type' => 'test',
        'test' => test.path,
        'success' => successful?,
        'expected_to_succeed' => expected_to_succeed?,
        'expected_result' => expected_result?,
        'elapsed_time' => elapsed_time,
        'state_dir' => state_dir,
        'script_results' => script_results.map(&:to_h)
      }
    end

    # @param test [Test]
    # @param scripts_by_name [Hash<String, TestScript>]
    # @param json [Hash]
    # @return [TestResult]
    def self.from_h(test, scripts_by_name, json)
      script_results = json.fetch('script_results').map do |sr|
        script = scripts_by_name.fetch(sr.fetch('script'))
        TestScriptResult.from_h(script, sr)
      end

      new(
        test,
        script_results,
        json.fetch('success'),
        json.fetch('elapsed_time'),
        json.fetch('state_dir')
      )
    end

    def to_json(*)
      to_h.to_json(*)
    end
  end
end
