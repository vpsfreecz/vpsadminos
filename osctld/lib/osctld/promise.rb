require 'libosctl'

module OsCtld
  class Promise
    class Token
      def initialize
        @queue = OsCtl::Lib::Queue.new
      end

      # Wait until the promise is fulfilled
      # @param timeout [Integer]
      # @return [true, nil]
      def wait(timeout: 60)
        @queue.pop(timeout:)
      end

      # Fulfil the promise
      def fulfil
        @queue << true
      end
    end

    def initialize
      @mutex = Mutex.new
      @tokens = []
      @fulfilled = false
    end

    # @return [Token]
    def add
      t = Token.new
      @mutex.synchronize do
        if @fulfilled
          t.fulfil
        else
          @tokens << t
        end
      end
      t
    end

    def fulfil
      @mutex.synchronize do
        @fulfilled = true
        @tokens.each(&:fulfil)
        @tokens.clear
      end
      nil
    end
  end
end
