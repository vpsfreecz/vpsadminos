# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::GarbageCollector do
  def cmd(args: [], opts: {}, gopts: {})
    build_command(described_class, args:, opts:, gopts:)
  end

  it 'prunes selected pools' do
    command = cmd(args: %w[tank pond])

    expect(command).to receive(:osctld_fmt).with(:garbage_collector_prune, cmd_opts: { pools: %w[tank pond] })

    command.prune
  end
end
