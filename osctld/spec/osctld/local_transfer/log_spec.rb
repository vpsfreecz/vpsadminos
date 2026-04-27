# frozen_string_literal: true

require 'osctld/local_transfer/log'

RSpec.describe OsCtld::LocalTransfer::Log do
  let(:dataset_map) do
    [
      described_class::Dataset.new(
        relative_name: '/',
        source: 'tank/ct/ct1',
        target: 'tank/ct/ct1-copy'
      ),
      described_class::Dataset.new(
        relative_name: 'data',
        source: 'tank/ct/ct1/data',
        target: 'tank/ct/ct1-copy/data'
      )
    ]
  end

  let(:options) do
    {
      operation: :copy,
      target_pool: 'tank',
      target_id: 'ct1-copy',
      target_dataset: 'tank/ct/ct1-copy',
      target_dataset_custom: false,
      target_user: 'alice',
      target_group: '/default',
      network_interfaces: true,
      datasets: dataset_map
    }
  end

  it 'round-trips logs through dump and load' do
    log = described_class.new(
      role: :source,
      state: :incremental,
      snapshots: %w[snap-base snap-incr],
      state_snapshot: 'snap-state',
      state_running: true,
      opts: options
    )

    expect(described_class.load(log.dump).dump).to eq(log.dump)
  end

  it 'loads and dumps dataset maps' do
    cfg = dataset_map.first.dump

    expect(described_class::Dataset.load(cfg).dump).to eq(cfg)
  end

  it 'exposes operation predicates' do
    copy = described_class::Options.new(options)
    move = described_class::Options.new(options.merge(operation: :move))

    expect(copy.copy?).to be(true)
    expect(copy.move?).to be(false)
    expect(move.copy?).to be(false)
    expect(move.move?).to be(true)
  end

  it 'rejects unsupported options' do
    expect do
      described_class::Options.new(options.merge(unknown: true))
    end.to raise_error(ArgumentError, /unsupported options: unknown/)
  end

  it 'uses local transfer continuation rules' do
    log = described_class.new(role: :source, state: :base, snapshots: [], opts: options)

    expect(log.can_local_continue?(:base)).to be(false)
    expect(log.can_local_continue?(:incremental)).to be(true)
    log.state = :incremental
    expect(log.can_local_continue?(:incremental)).to be(true)
    expect(log.can_local_continue?(:transfer)).to be(true)
  end

  it 'does not free any token on close' do
    log = described_class.new(role: :source, opts: options)

    expect { log.close }.not_to raise_error
  end
end
