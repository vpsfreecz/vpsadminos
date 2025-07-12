module TestRunner
  class Example
    # @return [ExampleGroup]
    attr_reader :group

    # @return [String]
    attr_reader :message

    def initialize(group, message, pending: false, skip: false, &block)
      @group = group
      @message = message
      @pending = pending
      @skip = skip
      @block = block
    end

    def pending?
      @pending
    end

    def skip?
      @skip
    end

    def evaluate?
      !skip?
    end

    def full_message
      "#{group.message} #{message}"
    end

    def reason
      if @pending
        @pending.is_a?(String) ? @pending : 'Example is pending'
      elsif @skip
        @skip.is_a?(String) ? @skip : 'Example is skipped'
      end
    end

    def evaluate
      t1 = Time.now

      begin
        catch(:skip) do
          @block.call
        end
      rescue StandardError, RSpec::Expectations::ExpectationNotMetError => e
        ExampleResult.new(self, Time.now - t1, e)
      else
        ExampleResult.new(self, Time.now - t1)
      ensure
        @block = nil
      end
    end

    protected

    def set_pending
      @pending = true
    end

    def set_skip
      @skip = true
    end
  end
end
