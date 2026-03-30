# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/zfs/objset_stats/objset'
require 'libosctl/zfs/objset_stats/pool_tree'
require 'libosctl/zfs/objset_stats/tree'

RSpec.describe OsCtl::Lib::Zfs::ObjsetStats::Tree do
  it 'looks datasets up across pools and aggregates stats' do
    tank_root = OsCtl::Lib::Zfs::ObjsetStats::Objset.new
    tank_root.dataset_name = 'tank'
    tank_root.write_ios = 1

    tank_child = OsCtl::Lib::Zfs::ObjsetStats::Objset.new
    tank_child.dataset_name = 'tank/ct'
    tank_child.write_ios = 2

    tank_tree = OsCtl::Lib::Zfs::ObjsetStats::PoolTree.new('tank')
    tank_tree << tank_root
    tank_tree << tank_child
    tank_tree.build

    fast_root = OsCtl::Lib::Zfs::ObjsetStats::Objset.new
    fast_root.dataset_name = 'fast'
    fast_root.write_ios = 3

    fast_tree = OsCtl::Lib::Zfs::ObjsetStats::PoolTree.new('fast')
    fast_tree << fast_root
    fast_tree.build

    tree = described_class.new
    tree << tank_tree
    tree << fast_tree

    expect(tree['tank/ct']).to eq(tank_child)
    expect(tree.aggregate_stats.write_ios).to eq(6)
  end
end
