# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/zfs/objset_stats/objset'

RSpec.describe OsCtl::Lib::Zfs::ObjsetStats::Objset do
  it 'starts with zeroed counters and empty subdatasets' do
    objset = described_class.new

    expect(objset.write_ios).to eq(0)
    expect(objset.write_bytes).to eq(0)
    expect(objset.read_ios).to eq(0)
    expect(objset.read_bytes).to eq(0)
    expect(objset.subdatasets).to eq([])
  end

  it 'aggregates its own stats with descendant stats' do
    root = described_class.new
    root.dataset_name = 'tank'
    root.write_ios = 1
    root.write_bytes = 2
    root.read_ios = 3
    root.read_bytes = 4

    child = described_class.new
    child.dataset_name = 'tank/ct'
    child.write_ios = 5
    child.write_bytes = 6
    child.read_ios = 7
    child.read_bytes = 8

    grandchild = described_class.new
    grandchild.dataset_name = 'tank/ct/root'
    grandchild.write_ios = 9
    grandchild.write_bytes = 10
    grandchild.read_ios = 11
    grandchild.read_bytes = 12

    child.subdatasets << grandchild
    root.subdatasets << child

    aggregate = root.aggregate_stats

    expect(aggregate.write_ios).to eq(15)
    expect(aggregate.write_bytes).to eq(18)
    expect(aggregate.read_ios).to eq(21)
    expect(aggregate.read_bytes).to eq(24)
  end

  it 'returns cached totals on repeated aggregation' do
    root = described_class.new
    root.dataset_name = 'tank'
    root.write_ios = 1

    child = described_class.new
    child.dataset_name = 'tank/ct'
    child.write_ios = 2

    root.subdatasets << child

    aggregate = root.aggregate_stats
    cached = root.aggregate_stats

    expect(cached).to be(aggregate)
    expect(cached.write_ios).to eq(3)
  end

  it 'does not double-count cached stats when aggregating into an external accumulator' do
    root = described_class.new
    root.dataset_name = 'tank'
    root.write_ios = 1

    child = described_class.new
    child.dataset_name = 'tank/ct'
    child.write_ios = 2

    root.subdatasets << child

    expect(root.aggregate_stats.write_ios).to eq(3)

    into = described_class::AggregatedStats.new(0, 0, 0, 0)
    root.aggregate_stats(into:)

    expect(into.write_ios).to eq(3)
    expect(into.write_bytes).to eq(0)
    expect(into.read_ios).to eq(0)
    expect(into.read_bytes).to eq(0)
  end
end
