require 'gli'

module OsVm::Cli
  class App
    include GLI::App

    def self.get
      cli = new
      cli.setup
      cli
    end

    def self.run
      exit(get.run(ARGV))
    end

    def setup
      program_desc 'vpsAdminOS test suite evaluator'
      version OsVm::VERSION
      subcommand_option_handling :normal
      preserve_argv true
      arguments :strict
      hide_commands_without_desc true

      desc 'Run ruby script'
      arg_name '<file> [args...]'
      command 'script' do |c|
        c.action(&Command.run(:script))
      end
    end
  end
end
