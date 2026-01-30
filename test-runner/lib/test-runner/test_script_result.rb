require 'json'

module TestRunner
  class TestScriptResult
    # @return [TestScript]
    attr_reader :test_script

    # @return [Boolean]
    attr_reader :success

    # @return [Float]
    attr_reader :elapsed_time

    def initialize(test_script, success, elapsed_time)
      @test_script = test_script
      @success = success
      @elapsed_time = elapsed_time
    end

    def successful?
      @success
    end

    def failed?
      !@success
    end

    def expected_result?
      if test_script.expect_failure
        !@success
      else
        @success
      end
    end

    def unexpected_result?
      !expected_result?
    end

    def expected_to_succeed?
      !test_script.expect_failure
    end

    def expected_to_fail?
      test_script.expect_failure
    end

    # @return [Hash]
    def to_h
      {
        'type' => 'script',
        'script' => test_script.name,
        'success' => success,
        'elapsed_time' => elapsed_time,
        'expected_to_succeed' => expected_to_succeed?,
        'expected_result' => expected_result?
      }
    end

    # @param json [Hash]
    # @return [TestScriptResult]
    def self.from_h(test_script, json)
      new(
        test_script,
        json.fetch('success'),
        json.fetch('elapsed_time')
      )
    end

    def to_json(*)
      to_h.to_json(*)
    end
  end
end
