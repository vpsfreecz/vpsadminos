module TestRunner
  class ExampleResult
    # @return [Example]
    attr_reader :example

    # @return [Exception]
    attr_reader :exception

    # @return [Float]
    attr_reader :elapsed_time

    # @param example [Example]
    # @param elapsed_time [Float]
    # @param exception [Exception, nil]
    def initialize(example, elapsed_time, exception = nil)
      @example = example
      @elapsed_time = elapsed_time
      @exception = exception
    end

    def success?
      @exception.nil?
    end

    def failure?
      !success?
    end

    def title
      example.full_message
    end

    def error
      @exception.message
    end
  end
end
