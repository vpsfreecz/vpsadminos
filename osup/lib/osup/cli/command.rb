require 'libosctl'

module OsUp
 class Cli::Command
    def self.run(klass, method)
      Proc.new do |global_opts, opts, args|
        if global_opts[:debug]
          OsCtl::Lib::Logger.setup(:stdout)
        else
          OsCtl::Lib::Logger.setup(:none)
        end

        cmd = klass.new(global_opts, opts, args)
        cmd.method(method).call
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
