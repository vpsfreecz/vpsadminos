require 'libosctl'

module VpsAdminOS::Converter
 class Cli::Command < OsCtl::Lib::Cli::Command
    def self.run(klass, method)
      Proc.new do |global_opts, opts, args|
        cmd = klass.new(global_opts, opts, args)
        cmd.method(method).call
      end
    end

    def initialize(global_opts, opts, args)
      super

      if gopts['log-file']
        OsCtl::Lib::Logger.setup(:io, io: File.open(gopts['log-file'], 'a'))
      else
        OsCtl::Lib::Logger.setup(:none)
      end
    end
  end
end
