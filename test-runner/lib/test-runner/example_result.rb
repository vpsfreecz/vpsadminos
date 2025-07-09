module TestRunner
  class ExampleResult
    # @return [Example]
    attr_reader :example

    # @return [Exception]
    attr_reader :exception

    # @param example [Example]
    # @param exception [Exception, nil]
    def initialize(example, exception = nil)
      @example = example
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
