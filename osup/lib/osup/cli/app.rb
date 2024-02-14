require 'gli'

module OsUp::Cli
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
      Thread.abort_on_exception = true

      program_desc 'System upgrade manager for vpsAdminOS'
      version OsUp::VERSION
      subcommand_option_handling :normal
      preserve_argv true
      arguments :strict
      hide_commands_without_desc true

      desc 'Do not make any changes, just print what would happen'
      switch %i[n dry-run], negatable: false

      desc 'Print executed commands'
      switch %i[d debug], negatable: false

      desc 'Show status of all pools or a selected pool'
      arg_name '[pool]'
      command :status do |c|
        c.desc 'Do not show header'
        c.switch %i[H hide-header], negatable: false

        c.action(&Command.run(Main, :status))
      end

      desc 'Check status of all pools or a selected pool'
      arg_name '[pool]'
      command :check do |c|
        c.action(&Command.run(Main, :check))
      end

      desc 'Check flags for rollback to a specific version'
      arg_name '<pool> <version>'
      command 'check-rollback' do |c|
        c.action(&Command.run(Main, :check_rollback))
      end

      desc 'Initialize osup on selected pool'
      arg_name '<pool>'
      command :init do |c|
        c.desc 'Overwrite existing version file'
        c.switch %i[f force], negatable: false

        c.action(&Command.run(Main, :init))
      end

      desc 'Upgrade selected pool'
      arg_name '<pool> [version]'
      command :upgrade do |c|
        c.action(&Command.run(Main, :upgrade))
      end

      desc 'Upgrade all pools'
      arg_name '[version]'
      command 'upgrade-all' do |c|
        c.action(&Command.run(Main, :upgrade_all))
      end

      desc 'Rollback selected pool'
      arg_name '<pool> [version]'
      command :rollback do |c|
        c.action(&Command.run(Main, :rollback))
      end

      desc 'Rollback all pools'
      arg_name '[version]'
      command 'rollback-all' do |c|
        c.action(&Command.run(Main, :rollback_all))
      end

      command 'gen-completion' do |g|
        g.command :bash do |c|
          c.action(&Command.run(Main, :gen_bash_completion))
        end
      end

      # desc 'Execute migration' (do not uncomment this line to hide it from help)
      arg_name '<pool> <migration dirname> <action>'
      command :run do |c|
        c.action(&Command.run(Runner, :run))
      end
    end
  end
end
