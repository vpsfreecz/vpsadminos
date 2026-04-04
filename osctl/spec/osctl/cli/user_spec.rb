# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::User do
  def cmd(args: [], opts: {}, gopts: {})
    build_command(described_class, args:, opts:, gopts:)
  end

  let(:keyring) { instance_double(OsCtl::Cli::KernelKeyring, list_param_names: [], add_user_values: nil) }

  before do
    allow(OsCtl::Cli::KernelKeyring).to receive(:new).and_return(keyring)
  end

  it 'maps --registered to a boolean filter without treating it as a string list' do
    command = cmd(opts: { registered: true })
    expect(command).to receive(:osctld_call).with(:user_list, registered: true).and_return([])
    allow(command).to receive(:format_output)

    command.list
  end

  it 'maps --unregistered to false' do
    command = cmd(opts: { unregistered: true })
    expect(command).to receive(:osctld_call).with(:user_list, registered: false).and_return([])
    allow(command).to receive(:format_output)

    command.list
  end

  it 'still comma-splits pool filters' do
    command = cmd(gopts: { pool: 'tank,pond' }, opts: { registered: true })
    expect(command).to receive(:osctld_call).with(
      :user_list,
      registered: true,
      pool: %w[tank pond]
    ).and_return([])
    allow(command).to receive(:format_output)

    command.list
  end
end
