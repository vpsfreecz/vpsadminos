# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/zfs/objset_stats/objset'
require 'libosctl/zfs/objset_stats/pool_tree'

RSpec.describe OsCtl::Lib::Zfs::ObjsetStats::PoolTree do
  it 'builds parent/child placement and aggregates pool stats' do
    root = OsCtl::Lib::Zfs::ObjsetStats::Objset.new
    root.dataset_name = 'tank'
    root.write_ios = 1
    root.write_bytes = 2
    root.read_ios = 3
    root.read_bytes = 4

    child = OsCtl::Lib::Zfs::ObjsetStats::Objset.new
    child.dataset_name = 'tank/ct'
    child.write_ios = 5
    child.write_bytes = 6
    child.read_ios = 7
    child.read_bytes = 8

    grandchild = OsCtl::Lib::Zfs::ObjsetStats::Objset.new
    grandchild.dataset_name = 'tank/ct/root'
    grandchild.write_ios = 9
    grandchild.write_bytes = 10
    grandchild.read_ios = 11
    grandchild.read_bytes = 12

    tree = described_class.new('tank')
    tree << root
    tree << grandchild
    tree << child
    tree.build

    expect(tree.root.subdatasets.map(&:dataset_name)).to eq(['tank/ct'])
    expect(tree['tank/ct'].subdatasets.map(&:dataset_name)).to eq(['tank/ct/root'])

    aggregate = tree.aggregate_stats

    expect(aggregate.write_ios).to eq(15)
    expect(aggregate.write_bytes).to eq(18)
    expect(aggregate.read_ios).to eq(21)
    expect(aggregate.read_bytes).to eq(24)
  end
end
