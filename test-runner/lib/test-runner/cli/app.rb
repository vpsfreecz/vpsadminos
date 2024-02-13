require 'gli'

module TestRunner::Cli
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
      version TestRunner::VERSION
      subcommand_option_handling :normal
      preserve_argv true
      arguments :strict
      hide_commands_without_desc true

      desc 'List available tests'
      arg_name '[path-pattern]'
      command 'ls' do |c|
        c.action(&Command.run(:list))
      end

      desc 'Run test'
      arg_name '[path-pattern]'
      command 'test' do |c|
        c.desc 'How many tests to run in parallel'
        c.flag %w[j jobs], type: Integer, default_value: 1

        c.desc 'Default timeout for machine commands, in seconds'
        c.flag %w[t timeout], type: Integer, default_value: 900

        c.desc 'Stop testing when one test fails'
        c.switch 'stop-on-failure', default_value: false

        c.desc 'Determines where machine disk files are kept'
        c.switch 'destructive', default_value: true

        c.desc 'Directory where test logs and state are stored'
        c.flag 'state-dir'

        c.action(&Command.run(:test))
      end

      desc 'Debug test'
      arg_name '<test>'
      command 'debug' do |c|
        c.desc 'Directory where test logs and state are stored'
        c.flag 'state-dir'

        c.desc 'Default timeout for machine commands, in seconds'
        c.flag %w[t timeout], type: Integer, default_value: 900

        c.action(&Command.run(:debug))
      end

      default_command 'ls'
    end
  end
end
