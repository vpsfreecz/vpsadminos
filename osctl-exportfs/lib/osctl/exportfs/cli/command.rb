require 'libosctl'

module OsCtl::ExportFS::Cli
  class Command < OsCtl::Lib::Cli::Command
    def self.run(klass, method)
      Proc.new do |global_opts, opts, args|
        cmd = klass.new(global_opts, opts, args)
        cmd.method(method).call
      end
    end

    def initialize(global_opts, opts, args)
      super
      OsCtl::Lib::Logger.setup(:stdout)
    end
  end
end
