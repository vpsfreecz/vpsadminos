# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/utils/log'
require 'libosctl/utils/system'
require 'libosctl/zfs/dataset'
require 'libosctl/zfs/snapshot'

RSpec.describe OsCtl::Lib::Zfs::Snapshot do
  it 'exposes dataset, snapshot name, string name, and mutable properties' do
    dataset = OsCtl::Lib::Zfs::Dataset.new('tank/ct/test', base: 'tank/ct/test')
    snapshot = described_class.new(dataset, 'snap1')

    snapshot.properties['creation'] = '123'

    expect(snapshot.dataset).to eq(dataset)
    expect(snapshot.snapshot).to eq('snap1')
    expect(snapshot.name).to eq('tank/ct/test@snap1')
    expect(snapshot.to_s).to eq('tank/ct/test@snap1')
    expect(snapshot.properties).to eq('creation' => '123')
  end
end
