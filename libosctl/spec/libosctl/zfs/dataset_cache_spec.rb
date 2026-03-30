# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/utils/log'
require 'libosctl/utils/system'
require 'libosctl/zfs/dataset'
require 'libosctl/zfs/dataset_cache'

RSpec.describe OsCtl::Lib::Zfs::DatasetCache do
  it 'looks datasets up by name' do
    ds = OsCtl::Lib::Zfs::Dataset.new('tank/ct/test', base: 'tank/ct/test')
    cache = described_class.new([ds])

    expect(cache['tank/ct/test']).to eq(ds)
    expect(cache['tank/missing']).to be_nil
  end
end
