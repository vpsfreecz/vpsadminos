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
    end

    # @return [Token]
    def add
      t = Token.new
      @tokens << t
      t
    end

    def fulfil
      @tokens.each(&:fulfil)
      nil
    end
  end
end
