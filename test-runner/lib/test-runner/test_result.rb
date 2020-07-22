module TestRunner
  class TestResult
    attr_reader :test, :success, :elapsed_time, :state_dir

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
  end
end
