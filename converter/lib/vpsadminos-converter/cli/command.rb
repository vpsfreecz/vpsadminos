require 'libosctl'

module VpsAdminOS::Converter
 class Cli::Command
    def self.run(klass, method)
      Proc.new do |global_opts, opts, args|
        cmd = klass.new(global_opts, opts, args)
        cmd.method(method).call
      end
    end

    attr_reader :gopts, :opts, :args

    def initialize(global_opts, opts, args)
      @gopts = global_opts
      @opts = opts
      @args = args

      if gopts['log-file']
        OsCtl::Lib::Logger.setup(:io, io: File.open(gopts['log-file'], 'a'))
      else
        OsCtl::Lib::Logger.setup(:none)
      end
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
