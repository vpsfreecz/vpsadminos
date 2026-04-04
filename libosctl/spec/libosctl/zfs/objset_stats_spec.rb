# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/zfs/objset_stats'
require 'libosctl/zfs/objset_stats/parser'
require 'libosctl/zfs/objset_stats/tree'

RSpec.describe OsCtl::Lib::Zfs::ObjsetStats do
  describe '.read_pool' do
    it 'delegates to the parser' do
      parser = instance_double(described_class::Parser)
      pool_tree = instance_double(described_class::PoolTree)

      allow(described_class::Parser).to receive(:new).and_return(parser)
      allow(parser).to receive(:read).with('tank').and_return(pool_tree)

      expect(described_class.read_pool('tank')).to eq(pool_tree)
    end
  end

  describe '.read_pools' do
    it 'builds a tree from each requested pool' do
      tree = instance_spy(described_class::Tree)
      tank_tree = instance_double(described_class::PoolTree)
      fast_tree = instance_double(described_class::PoolTree)

      allow(described_class::Tree).to receive(:new).and_return(tree)
      allow(described_class).to receive(:read_pool).with('tank').and_return(tank_tree)
      allow(described_class).to receive(:read_pool).with('fast').and_return(fast_tree)

      expect(described_class.read_pools(%w[tank fast])).to eq(tree)
      expect(tree).to have_received(:<<).with(tank_tree).ordered
      expect(tree).to have_received(:<<).with(fast_tree).ordered
    end
  end
end
