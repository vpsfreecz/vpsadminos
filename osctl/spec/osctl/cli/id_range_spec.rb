# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::IdRange do
  def cmd(args: [], opts: {}, gopts: {})
    build_command(described_class, args:, opts:, gopts:)
  end

  it 'creates and deletes id ranges' do
    create = cmd(args: ['main'], opts: { 'start-id' => 100_000, 'block-size' => 65_536, 'block-count' => 10 }, gopts: { pool: 'tank' })
    delete = cmd(args: ['main'], gopts: { pool: 'tank' })

    expect(create).to receive(:osctld_fmt).with(
      :id_range_create,
      cmd_opts: {
        pool: 'tank',
        name: 'main',
        start_id: 100_000,
        block_size: 65_536,
        block_count: 10
      }
    )
    create.create

    expect(delete).to receive(:osctld_fmt).with(
      :id_range_delete,
      cmd_opts: { pool: 'tank', name: 'main' }
    )
    delete.delete
  end

  it 'formats table listings and single block views' do
    list = cmd(args: %w[main allocated], gopts: { pool: 'tank' })
    show = cmd(args: %w[main 4], gopts: { pool: 'tank' })

    expect(list).to receive(:osctld_fmt) do |_msg, cmd_opts:, fmt_opts:|
      expect(cmd_opts).to eq(pool: 'tank', name: 'main', type: 'allocated')
      expect(fmt_opts[:layout]).to eq(:columns)
    end
    list.table_list

    expect(show).to receive(:osctld_fmt).with(
      :id_range_table_show,
      cmd_opts: { name: 'main', pool: 'tank', block_index: 4 },
      fmt_opts: hash_including(layout: :rows)
    )
    show.table_show
  end

  it 'requires either --block-index or --owner for free' do
    expect { cmd(args: ['main']).free }.to raise_error(GLI::BadCommandLine, 'use --block-index or --owner')
    expect { cmd(args: ['main'], opts: { 'block-index' => 1, 'owner' => 'u' }).free }.to raise_error(GLI::BadCommandLine, 'use --block-index or --owner')
  end

  it 'frees blocks by owner or block index' do
    command = cmd(args: ['main'], opts: { 'block-index' => 2 }, gopts: { pool: 'tank' })

    expect(command).to receive(:osctld_fmt).with(
      :id_range_free,
      cmd_opts: { pool: 'tank', name: 'main', block_index: 2, owner: nil }
    )

    command.free
  end
end
