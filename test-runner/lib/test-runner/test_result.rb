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
  end
end
