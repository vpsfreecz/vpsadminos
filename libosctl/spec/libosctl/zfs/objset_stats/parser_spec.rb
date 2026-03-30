# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/zfs/objset_stats/objset'
require 'libosctl/zfs/objset_stats/pool_tree'
require 'libosctl/zfs/objset_stats/parser'

RSpec.describe OsCtl::Lib::Zfs::ObjsetStats::Parser do
  it 'parses objset files and ignores missing entries' do
    with_tmpdir do |dir|
      pool_dir = File.join(dir, 'proc/spl/kstat/zfs/tank')
      FileUtils.mkdir_p(pool_dir)

      root = File.join(pool_dir, 'objset-1')
      child = File.join(pool_dir, 'objset-2')
      missing = File.join(pool_dir, 'objset-3')

      File.write(root, <<~OBJSET)
        header
        header
        dataset_name 7 tank
        writes 4 1
        nwritten 4 2
        reads 4 3
        nread 4 4
      OBJSET

      File.write(child, <<~OBJSET)
        header
        header
        dataset_name 7 tank/ct
        writes 4 5
        nwritten 4 6
        reads 4 7
        nread 4 8
      OBJSET

      allow(Dir).to receive(:glob).with('/proc/spl/kstat/zfs/tank/objset-*').and_return([root, child, missing])

      tree = described_class.new.read('tank')

      expect(tree.root.dataset_name).to eq('tank')
      expect(tree['tank/ct']).to have_attributes(write_ios: 5, write_bytes: 6, read_ios: 7, read_bytes: 8)
      expect(tree.root.subdatasets.map(&:dataset_name)).to eq(['tank/ct'])
    end
  end
end
