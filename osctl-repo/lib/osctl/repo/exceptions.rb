module OsCtl
  module Repo
    class TemplateNotFound < StandardError
      def initialize(template)
        super(template.to_s)
      end
    end

    class FormatNotFound < StandardError
      def initialize(template, format)
        super("#{template}: #{format}")
      end
    end

    class BadHttpResponse < StandardError
      def initialize(code)
        super("HTTP server returned #{code}")
      end
    end
  end
end
