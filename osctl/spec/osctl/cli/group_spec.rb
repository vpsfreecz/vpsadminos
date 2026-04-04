# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Group do
  def cmd(args: [], opts: {}, gopts: {})
    build_command(described_class, args:, opts:, gopts:)
  end

  it 'dispatches device_promote to the promote helper without requiring a mode argument' do
    command = cmd(args: %w[grp1 char 1 3], gopts: { pool: 'tank' })

    expect(command).to receive(:do_device_promote).with(
      :group_device_promote,
      name: 'grp1',
      pool: 'tank'
    )
    expect(command).not_to receive(:do_device_chmod)

    command.device_promote
  end
end
