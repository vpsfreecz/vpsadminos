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
      def initialize(code)
        super("HTTP server returned #{code}")
      end
    end

    class NetworkError < StandardError
      def initialize(exception)
        super(exception.message)
      end
    end

    class CacheMiss < StandardError; end
  end
end
