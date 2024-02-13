require 'libosctl'

module OsUp
  class Cli::Command < OsCtl::Lib::Cli::Command
    def self.run(klass, method)
      proc do |global_opts, opts, args|
        if global_opts[:debug]
          OsCtl::Lib::Logger.setup(:stdout)
        else
          OsCtl::Lib::Logger.setup(:none)
        end

        cmd = klass.new(global_opts, opts, args)
        cmd.method(method).call
      end
    end
  end
end
