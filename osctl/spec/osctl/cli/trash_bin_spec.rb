# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::TrashBin do
  def cmd(args: [], opts: {}, gopts: {})
    build_command(described_class, args:, opts:, gopts:)
  end

  it 'adds datasets and prunes selected pools' do
    add = cmd(args: ['tank/trash'])
    prune = cmd(args: %w[tank pond])

    expect(add).to receive(:osctld_fmt).with(:trash_bin_dataset_add, cmd_opts: { dataset: 'tank/trash' })
    add.dataset_add

    expect(prune).to receive(:osctld_fmt).with(:trash_bin_prune, cmd_opts: { pools: %w[tank pond] })
    prune.prune
  end
end
