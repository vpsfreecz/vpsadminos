# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/cli/completion/bash'

RSpec.describe OsCtl::Lib::Cli::Completion::Bash do
  let(:install_cmd) do
    FakeCliCompletionHelpers::FakeCommand.new(
      name: :install,
      description: 'install pool',
      commands: {},
      switches: {},
      flags: {
        dataset: FakeCliCompletionHelpers::FakeFlag.new(['--dataset=DATASET'], nil),
        compression: FakeCliCompletionHelpers::FakeFlag.new(
          ['--compression=MODE'],
          %w[auto off gzip]
        )
      },
      arguments_description: '<pool> [selector]',
      aliases: [:i]
    )
  end

  let(:pool_cmd) do
    FakeCliCompletionHelpers::FakeCommand.new(
      name: :pool,
      description: 'pool operations',
      commands: {
        install: install_cmd,
        _hidden: FakeCliCompletionHelpers::FakeCommand.new(
          name: :_hidden,
          description: nil,
          commands: {},
          switches: {},
          flags: {},
          arguments_description: nil,
          aliases: nil
        )
      },
      switches: {},
      flags: {},
      arguments_description: nil,
      aliases: [:pl]
    )
  end

  let(:app) do
    FakeCliCompletionHelpers::FakeApp.new(
      exe_name: 'osctl',
      commands: { pool: pool_cmd },
      switches: {
        json: FakeCliCompletionHelpers::FakeSwitch.new(['--[no-]json'])
      },
      flags: {
        pool: FakeCliCompletionHelpers::FakeFlag.new(['--pool=POOL'], nil)
      }
    )
  end

  it 'generates visible command functions, aliases, and completion bindings' do
    completion = described_class.new(app)
    completion.shortcuts = %w[ct]

    script = completion.generate

    expect(completion.app_prefix).to eq('_osctl')
    expect(script).to include('complete -F _osctl_completion_global osctl')
    expect(script).to include('complete -F _osctl_completion_short ct')
    expect(script).to include('_osctl_comp_cmd_osctl_pool')
    expect(script).to include('_osctl_comp_cmd_osctl_pl')
    expect(script).to include('_osctl_comp_cmd_osctl_pool_install')
    expect(script).to include('_osctl_comp_cmd_osctl_pool_i')
    expect(script).to include(
      '_osctl_process_args osctl_pool_install _cmd ${cmd[@]} ' \
      '_flags --dataset --compression _args pool selector'
    )
    expect(script).not_to include('_hidden')
  end

  it 'expands switches, flags, and custom option and argument providers' do
    completion = described_class.new(app)
    completion.opt(cmd: %i[osctl pool install], name: :dataset, expand: 'echo tank/ct')
    completion.arg(cmd: :all, name: :pool, expand: 'echo tank fast')

    script = completion.generate

    expect(script).to include('--json')
    expect(script).to include('--no-json')
    expect(script).to include('_osctl_comp_arg_osctl_pool_install__pool')
    expect(script).to include('echo tank/ct')
    expect(script).to include('echo auto off gzip')
    expect(script).to include('echo tank fast')
  end
end
