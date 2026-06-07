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
        c.desc 'Filter by label'
        c.flag %w[l label], multiple: true

        c.desc 'Filter by tag'
        c.flag %w[t tag], multiple: true

        c.desc 'Filter by metadata expression'
        c.flag 'filter', multiple: true

        c.desc 'Nix system to evaluate tests for'
        c.flag 'system', default_value: TestRunner::NixCli::DEFAULT_SYSTEM

        c.desc 'Path to a Nix file returning the test framework configuration'
        c.flag 'test-config'

        c.action(&Command.run(:list))
      end

      desc 'Run test'
      arg_name '[path-pattern]'
      command 'test' do |c|
        c.desc 'Filter by label'
        c.flag %w[l label], multiple: true

        c.desc 'Filter by tag'
        c.flag %w[t tag], multiple: true

        c.desc 'Filter by metadata expression'
        c.flag 'filter', multiple: true

        c.desc 'How many tests to run in parallel'
        c.flag %w[j jobs], type: Integer, default_value: 1

        c.desc 'Maximum memory available to running test VMs, in MiB'
        c.flag 'max-memory-mib', type: Integer

        c.desc 'Maximum /dev/shm space available to running test VMs, in MiB'
        c.flag 'max-shm-mib', type: Integer

        c.desc 'Memory to reserve from detected capacity, in MiB'
        c.flag 'memory-reserve-mib', type: Integer

        c.desc '/dev/shm space to reserve from detected capacity, in MiB'
        c.flag 'shm-reserve-mib', type: Integer

        c.desc 'Recreate disk files'
        c.switch %w[f fresh], default_value: false

        c.desc 'Nix system to evaluate tests for'
        c.flag 'system', default_value: TestRunner::NixCli::DEFAULT_SYSTEM

        c.desc 'Path to a Nix file returning the test framework configuration'
        c.flag 'test-config'

        c.desc 'Default timeout for machine commands, in seconds'
        c.flag %w[timeout], type: Integer, default_value: 900

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

        c.desc 'Nix system to evaluate tests for'
        c.flag 'system', default_value: TestRunner::NixCli::DEFAULT_SYSTEM

        c.desc 'Path to a Nix file returning the test framework configuration'
        c.flag 'test-config'

        c.desc 'Default timeout for machine commands, in seconds'
        c.flag %w[t timeout], type: Integer, default_value: 900

        c.action(&Command.run(:debug))
      end

      default_command 'ls'
    end
  end
end
