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
    # @param v [Array] list of required arguments
    # @param optional [Array] list of optional arguments
    # @param strict [Boolean] do not allow more arguments than specified
    def require_args!(*v, optional: [], strict: true)
      if v.count == 1 && v.first.is_a?(Array)
        required = v.first
      else
        required = v
      end

      if args.count < required.count
        arg = required[ args.count ]
        raise GLI::BadCommandLine, "missing argument <#{arg}>"

      elsif strict && args.count > (required.count + optional.count)
        unknown = args[ (required.count + optional.count) .. -1 ]

        msg = ''

        if unknown.count > 1
          msg << 'unknown arguments: '
        else
          msg << 'unknown argument: '
        end

        msg << unknown.join(' ')

        if unknown.detect { |v| v.start_with?('--') }
          msg << "\n"
          msg << 'Note that options must come before arguments.'
        end

        raise GLI::BadCommandLine, msg
      end
    end
  end
end
