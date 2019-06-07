require 'gli'
require 'thread'

module OsCtl::Image::Cli
  class App
    include GLI::App

    def self.run
      cli = new
      cli.setup
      exit(cli.run(ARGV))
    end

    def setup
      Thread.abort_on_exception = true

      program_desc 'Build, test and deploy vpsAdminOS images'
      version OsCtl::Image::VERSION
      subcommand_option_handling :normal
      preserve_argv true
      arguments :strict

      desc 'List available images'
      command 'ls' do |c|
        c.desc 'Select parameters to output'
        c.flag %i(o output), arg_name: 'parameters'

        c.desc 'Do not show header'
        c.switch %i(H hide-header), negatable: false

        c.desc 'List available parameters'
        c.switch %i(L list), negatable: false

        c.desc 'Sort by parameter(s)'
        c.flag %i(s sort), arg_name: 'parameters'

        c.action &Command.run(Image, :list)
      end

      desc 'Build image'
      arg_name '<image>[,image...]'
      command 'build' do |c|
        c.desc 'Output directory'
        c.flag 'output-dir', arg_name: 'dir', default_value: 'output'

        c.desc 'Build dataset'
        c.flag 'build-dataset', arg_name: 'filesystem', required: true

        c.desc 'Vendor name'
        c.flag 'vendor', arg_name: 'name'

        c.desc 'How many images build in parallel'
        c.flag 'jobs', arg_name: 'n', type: Integer, default_value: 1

        c.action &Command.run(Image, :build)
      end

      desc 'Test image'
      arg_name '<image>[,image...] [test[,test...]]'
      command 'test' do |c|
        c.desc 'Output directory'
        c.flag 'output-dir', arg_name: 'dir', default_value: 'output'

        c.desc 'Build dataset'
        c.flag 'build-dataset', arg_name: 'filesystem', required: true

        c.desc 'Vendor name'
        c.flag 'vendor', arg_name: 'name'

        c.desc 'Force image rebuild'
        c.switch 'rebuild'

        c.desc 'Keep containers from failed tests'
        c.switch 'keep-failed'

        c.action &Command.run(Image, :test)
      end

      desc 'Build the image and use it in a container'
      arg_name '<image>'
      command 'instantiate' do |c|
        c.desc 'Output directory'
        c.flag 'output-dir', arg_name: 'dir', default_value: 'output'

        c.desc 'Build dataset'
        c.flag 'build-dataset', arg_name: 'filesystem', required: true

        c.desc 'Vendor name'
        c.flag 'vendor', arg_name: 'name'

        c.desc 'Force image rebuild'
        c.switch 'rebuild'

        c.desc 'Instantiate in an existing container'
        c.flag 'container', arg_name: 'ctid'

        c.action &Command.run(Image, :instantiate)
      end

      desc 'Build image, test it and deploy to repository'
      arg_name '<image>[,image...] <repository>'
      command 'deploy' do |c|
        c.desc 'Output directory'
        c.flag 'output-dir', arg_name: 'dir', default_value: 'output'

        c.desc 'Build dataset'
        c.flag 'build-dataset', arg_name: 'filesystem', required: true

        c.desc 'Vendor name'
        c.flag 'vendor', arg_name: 'name'

        c.desc 'Tags'
        c.flag 'tag', multiple: true

        c.desc 'How many images build in parallel'
        c.flag 'jobs', arg_name: 'n', type: Integer, default_value: 1

        c.desc 'Force image rebuild'
        c.switch 'rebuild'

        c.desc 'Skip tests'
        c.switch 'skip-tests'

        c.desc 'Keep containers from failed tests'
        c.switch 'keep-failed'

        c.action &Command.run(Image, :deploy)
      end

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

        ct.desc 'Delete managed containers'
        ct.command :del do |c|
          c.desc 'Delete containers of selected type'
          c.flag 'type', must_match: %w(builder test instance)

          c.desc 'Do not ask and immediately delete the containers'
          c.switch %w(f force)

          c.action &Command.run(Containers, :delete)
        end
      end
    end
  end
end
