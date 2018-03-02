module OsCtl::Repo::Cli
 class Command
    def self.run(klass, method)
      Proc.new do |global_opts, opts, args|
        cmd = klass.new(global_opts, opts, args)

        begin
          cmd.method(method).call

        rescue OsCtl::Repo::TemplateNotFound => e
          raise GLI::CustomExit.new(
            "Template not found: #{e.message}",
            OsCtl::Repo::EXIT_TEMPLATE_NOT_FOUND
          )

        rescue OsCtl::Repo::FormatNotFound => e
          raise GLI::CustomExit.new(
            "Format not found: #{e.message}",
            OsCtl::Repo::EXIT_FORMAT_NOT_FOUND
          )

        rescue OsCtl::Repo::BadHttpResponse => e
          raise GLI::CustomExit.new(
            "Unexpected HTTP error: #{e.message}",
            OsCtl::Repo::EXIT_HTTP_ERROR
          )

        rescue OsCtl::Repo::NetworkError => e
          raise GLI::CustomExit.new(
            "Unexpected network error: #{e.message}",
            OsCtl::Repo::EXIT_NETWORK_ERROR
          )
        end
      end
    end

    attr_reader :gopts, :opts, :args

    def initialize(global_opts, opts, args)
      @gopts = global_opts
      @opts = opts
      @args = args
    end

    # @param v [Array] list of required arguments
    def require_args!(*v)
      if v.count == 1 && v.first.is_a?(Array)
        required = v.first
      else
        required = v
      end

      return if args.count >= required.count

      arg = required[ args.count ]
      raise GLI::BadCommandLine, "missing argument <#{arg}>"
    end
 end
end
