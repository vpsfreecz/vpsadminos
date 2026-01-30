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
      if @example.pending?
        !@exception.nil?
      else
        @example.skip? || @exception.nil?
      end
    end

    def failure?
      !success?
    end

    def pending?
      @example.pending?
    end

    def skip?
      @example.skip?
    end

    def title
      example.full_message
    end

    def error
      if @example.pending?
        "Example that was pending due to '#{@example.reason}' unexpectedly succeeded"
      elsif @example.skip?
        @example.reason
      else
        @exception.message
      end
    end

    # @return [Hash]
    def to_h(script:, progress:, total:)
      {
        'type' => 'example',
        'script' => script,
        'example' => example.full_message,
        'progress' => progress,
        'total' => total,
        'success' => success?,
        'pending' => pending?,
        'skip' => skip?,
        'elapsed_time' => elapsed_time
      }
    end
  end
end
