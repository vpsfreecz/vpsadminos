# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsUp::SystemState do
  it 'supports the configured snapshot aliases' do
    state = described_class.new('tank/osctl', 'migration-up', snapshot: %i[conf log hook])

    expect(state.instance_variable_get(:@datasets)).to eq(
      [
        'tank/osctl/conf',
        'tank/osctl/log',
        'tank/osctl/hook'
      ]
    )
  end

  it 'rejects unsupported snapshot aliases' do
    expect do
      described_class.new('tank/osctl', 'migration-up', snapshot: %i[conf invalid])
    end.to raise_error("unsupported snapshot 'invalid'")
  end

  it 'creates snapshots with the expected names' do
    state = described_class.new('tank/osctl', 'migration-up', snapshot: %i[conf log])
    allow(state).to receive(:zfs)

    state.create

    expect(state).to have_received(:zfs).with(
      :snapshot,
      nil,
      'tank/osctl/conf@osup-pre-migration-up tank/osctl/log@osup-pre-migration-up'
    )
  end

  it 'does not call zfs snapshot when there is nothing to snapshot' do
    state = described_class.new('tank/osctl', 'migration-up', snapshot: [])
    allow(state).to receive(:zfs)

    state.create

    expect(state).not_to have_received(:zfs)
  end

  it 'destroys created snapshots when committed' do
    state = described_class.new('tank/osctl', 'migration-up', snapshot: %i[conf hook])
    allow(state).to receive(:zfs)

    state.create
    state.commit

    expect(state).to have_received(:zfs).with(:destroy, nil, 'tank/osctl/conf@osup-pre-migration-up')
    expect(state).to have_received(:zfs).with(:destroy, nil, 'tank/osctl/hook@osup-pre-migration-up')
  end

  it 'rolls back and destroys every created snapshot' do
    state = described_class.new('tank/osctl', 'migration-up', snapshot: [:conf])
    allow(state).to receive(:zfs)

    state.create
    state.rollback

    expect(state).to have_received(:zfs).with(:rollback, '-r', 'tank/osctl/conf@osup-pre-migration-up')
    expect(state).to have_received(:zfs).with(:destroy, nil, 'tank/osctl/conf@osup-pre-migration-up')
  end
end
