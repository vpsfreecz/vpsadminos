# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Pool do
  def cmd(args: [], opts: {}, gopts: {})
    build_command(described_class, args:, opts:, gopts:)
  end

  it 'requires a pool name or --all for import' do
    expect { cmd.import }.to raise_error(GLI::BadCommandLine, 'specify pool name or --all')
  end

  it 'imports a named pool' do
    command = cmd(args: ['tank'], opts: { all: false, autostart: true })

    expect(command).to receive(:osctld_fmt).with(
      :pool_import,
      cmd_opts: { name: 'tank', all: false, autostart: true }
    )

    command.import
  end

  it 'exports or aborts export based on options' do
    aborting = cmd(args: ['tank'], opts: { abort: true })
    expect(aborting).to receive(:osctld_fmt).with(:pool_abort_export, cmd_opts: { name: 'tank' })
    aborting.export

    exporting = cmd(args: ['tank'], opts: { force: true, 'stop-containers' => true, 'unregister-users' => false, 'message' => 'bye', 'if-imported' => true })
    expect(exporting).to receive(:osctld_fmt).with(
      :pool_export,
      cmd_opts: {
        name: 'tank',
        force: true,
        stop_containers: true,
        unregister_users: false,
        message: 'bye',
        if_imported: true
      }
    )
    exporting.export
  end

  it 'installs pools with an optional dataset' do
    command = cmd(args: ['tank'], opts: { dataset: 'root/osctl' })

    expect(command).to receive(:osctld_fmt).with(
      :pool_install,
      cmd_opts: { name: 'tank', dataset: 'root/osctl' }
    )

    command.install
  end

  it 'formats the autostart queue in columns' do
    command = cmd(args: ['tank'])

    expect(command).to receive(:osctld_fmt) do |_msg, cmd_opts:, fmt_opts:|
      expect(cmd_opts).to eq(name: 'tank')
      expect(fmt_opts[:layout]).to eq(:columns)
    end

    command.autostart_queue
  end

  it 'sets and unsets pool options' do
    set_command = cmd(args: %w[tank 4])
    unset_command = cmd(args: ['tank'])

    expect(set_command).to receive(:osctld_fmt).with(:pool_set, cmd_opts: { name: 'tank', parallel_start: '4' })
    set_command.set(:parallel_start)

    expect(unset_command).to receive(:osctld_fmt).with(:pool_unset, cmd_opts: { name: 'tank', options: [:parallel_start] })
    unset_command.unset(:parallel_start)
  end
end
