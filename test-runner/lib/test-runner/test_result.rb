module TestRunner
  class TestResult
    # @return [Test]
    attr_reader :test

    # @return [Boolean]
    attr_reader :success

    # @return [Float]
    attr_reader :elapsed_time

    # @return [String]
    attr_reader :state_dir

    def initialize(test, success, elapsed_time, state_dir)
      @test = test
      @success = success
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
