# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::App do
  it 'builds the CLI app' do
    expect { described_class.get }.not_to raise_error
  end

  it 'includes representative top-level and helper-generated subcommands' do
    app = described_class.get
    top_level = app.commands.keys.map(&:to_s)
    ct_commands = app.commands[:ct].commands.keys.map(&:to_s)
    ct_set_commands = app.commands[:ct].commands[:set].commands.keys.map(&:to_s)
    ct_unset_commands = app.commands[:ct].commands[:unset].commands.keys.map(&:to_s)

    expect(top_level).to include(
      'pool',
      'id-ranges',
      'user',
      'group',
      'ct',
      'send',
      'receive',
      'repo',
      'cpu-scheduler',
      'event',
      'history',
      'debug',
      'gen-completion'
    )
    expect(ct_commands).to include('assets', 'cgparams', 'devices')
    expect(ct_set_commands).to include('attr', 'cpu-limit', 'memory-limit')
    expect(ct_unset_commands).to include('attr', 'cpu-limit', 'memory-limit')
  end
end
