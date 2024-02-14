module OsCtl::Lib
  # Utilities for command handlers in CLI
  class Cli::Command
    attr_reader :gopts, :opts, :args

    def initialize(global_opts, opts, args)
      @gopts = global_opts
      @opts = opts
      @args = args
    end

    protected

    # @param required [Array] list of required arguments
    # @param optional [Array] list of optional arguments
    # @param strict [Boolean] do not allow more arguments than specified
    def require_args!(*required, optional: [], strict: true)
      if args.count < required.count
        arg = required[args.count]
        raise GLI::BadCommandLine, "missing argument <#{arg}>"

      elsif strict && args.count > (required.count + optional.count)
        unknown = args[(required.count + optional.count)..]

        msg = ''

        msg << if unknown.count > 1
                 'unknown arguments: '
               else
                 'unknown argument: '
               end

        msg << unknown.join(' ')

        if unknown.detect { |v| v.start_with?('-') }
          msg << ' (note that options must come before arguments)'
        end

        raise GLI::BadCommandLine, msg
      end
    end
  end
end
