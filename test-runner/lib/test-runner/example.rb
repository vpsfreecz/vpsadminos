module TestRunner
  class Example
    # @return [ExampleGroup]
    attr_reader :group

    # @return [String]
    attr_reader :message

    def initialize(group, message, &block)
      @group = group
      @message = message
      @block = block
    end

    def full_message
      "#{group.message} #{message}"
    end

    def evaluate
      t1 = Time.now

      begin
        @block.call
      rescue StandardError, RSpec::Expectations::ExpectationNotMetError => e
        ExampleResult.new(self, Time.now - t1, e)
      else
        ExampleResult.new(self, Time.now - t1)
      ensure
        @block = nil
      end
    end
  end
end
