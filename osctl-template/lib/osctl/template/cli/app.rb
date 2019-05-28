require 'gli'
require 'thread'

module OsCtl::Template::Cli
  class App
    include GLI::App

    def self.run
      cli = new
      cli.setup
      exit(cli.run(ARGV))
    end

    def setup
      Thread.abort_on_exception = true

      program_desc 'Build, test and deploy vpsAdminOS templates'
      version OsCtl::Template::VERSION
      subcommand_option_handling :normal
      preserve_argv true
      arguments :strict

      desc 'List available templates'
      command 'ls' do |c|
        c.desc 'Select parameters to output'
        c.flag %i(o output), arg_name: 'parameters'

        c.desc 'Do not show header'
        c.switch %i(H hide-header), negatable: false

        c.desc 'List available parameters'
        c.switch %i(L list), negatable: false

        c.desc 'Sort by parameter(s)'
        c.flag %i(s sort), arg_name: 'parameters'

        c.action &Command.run(Template, :list)
      end

      desc 'Build template'
      arg_name '<template>'
      command 'build' do |c|
        c.desc 'Output directory'
        c.flag 'output-dir', arg_name: 'dir', default_value: 'output'

        c.desc 'Build dataset'
        c.flag 'build-dataset', arg_name: 'filesystem', required: true

        c.desc 'Vendor name'
        c.flag 'vendor', arg_name: 'name'

        c.action &Command.run(Template, :build)
      end

      desc 'Test template'
      arg_name '<template> [test...]'
      command 'test' do |c|
        c.desc 'Output directory'
        c.flag 'output-dir', arg_name: 'dir', default_value: 'output'

        c.desc 'Build dataset'
        c.flag 'build-dataset', arg_name: 'filesystem', required: true

        c.desc 'Vendor name'
        c.flag 'vendor', arg_name: 'name'

        c.desc 'Force template rebuild'
        c.switch 'rebuild'

        c.action &Command.run(Template, :test)
      end

      desc 'Build the template and use it in a container'
      arg_name '<template>'
      command 'instantiate' do |c|
        c.desc 'Output directory'
        c.flag 'output-dir', arg_name: 'dir', default_value: 'output'

        c.desc 'Build dataset'
        c.flag 'build-dataset', arg_name: 'filesystem', required: true

        c.desc 'Vendor name'
        c.flag 'vendor', arg_name: 'name'

        c.desc 'Force template rebuild'
        c.switch 'rebuild'

        c.desc 'Instantiate in an existing container'
        c.flag 'container', arg_name: 'ctid'

        c.action &Command.run(Template, :instantiate)
      end

      # command 'deploy'

      desc 'Manage build and test containers'
      command 'ct' do |ct|
        ct.desc 'List managed containers'
        ct.command :ls do |c|
          c.desc 'Select parameters to output'
          c.flag %i(o output), arg_name: 'parameters'

          c.desc 'Do not show header'
          c.switch %i(H hide-header), negatable: false

          c.desc 'List available parameters'
          c.switch %i(L list), negatable: false

          c.desc 'Sort by parameter(s)'
          c.flag %i(s sort), arg_name: 'parameters'

          c.action &Command.run(Containers, :list)
        end
      end
    end
  end
end
