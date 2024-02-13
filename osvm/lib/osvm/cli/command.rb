require 'libosctl'

module OsVm
  class Cli::Command < OsCtl::Lib::Cli::Command
    def self.run(method)
      proc do |global_opts, opts, args|
        cmd = new(global_opts, opts, args)
        cmd.method(method).call
      end
    end

    def script
      require_args!('file', strict: false)

      # Remove osvm command-line arguments, so that ARGV contains only arguments
      # for the script.
      ARGV.shift # script
      ARGV.shift # <name>

      load(args[0])
    end
  end
end
