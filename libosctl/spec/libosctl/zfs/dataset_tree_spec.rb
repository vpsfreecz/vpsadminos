# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/utils/log'
require 'libosctl/utils/system'
require 'libosctl/zfs/dataset'
require 'libosctl/zfs/dataset_tree'

RSpec.describe OsCtl::Lib::Zfs::DatasetTree do
  it 'adds properties, finds datasets, iterates the tree, and materializes datasets' do
    tree = described_class.new
    tree.add_property('tank', 'mountpoint', '/tank')
    tree.add_property('tank/ct', 'mountpoint', '/tank/ct')
    tree.add_property('tank/ct/test', 'quota', '10G')

    expect(tree['tank/ct/test'].properties).to eq('quota' => '10G')

    visited = []
    tree.each_tree_dataset { |dataset_tree| visited << dataset_tree.name }

    expect(visited).to eq([nil, 'tank', 'tank/ct', 'tank/ct/test'])

    dataset = tree['tank/ct'].as_dataset(base: 'tank')

    expect(dataset).to be_a(OsCtl::Lib::Zfs::Dataset)
    expect(dataset.name).to eq('tank/ct')
    expect(dataset.properties).to eq('mountpoint' => '/tank/ct')
  end
end
