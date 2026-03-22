module OsCtl
  module Repo
    class ImageNotFound < StandardError
      def initialize(image)
        super(image.to_s)
      end
    end

    class FormatNotFound < StandardError
      def initialize(image, format)
        super("#{image}: #{format}")
      end
    end

    class BadHttpResponse < StandardError
      attr_reader :code

      def initialize(code)
        @code = code.to_i
        super("HTTP server returned #{code}")
      end
    end

    class NetworkError < StandardError
      attr_reader :original_exception

      def initialize(exception)
        @original_exception = exception

        super(
          if exception.respond_to?(:message)
            exception.message
          else
            exception.to_s
          end
        )
      end
    end

    class CacheMiss < StandardError; end
  end
end
