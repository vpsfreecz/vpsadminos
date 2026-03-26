# frozen_string_literal: true

require 'osctld/id_map'

RSpec.describe OsCtld::IdMap do
  it 'loads a modern map from a string list' do
    map = described_class.load(['0:100000:65536'])

    expect(map.dump).to eq(['0:100000:65536'])
  end

  it 'loads the legacy offset and size representation' do
    map = described_class.load(nil, {
      'offset' => 200_000,
      'size' => 65_536
    })

    expect(map.dump).to eq(['0:200000:65536'])
  end

  it 'dumps map entries as strings' do
    map = described_class.load(['0:100000:65536', '1000:201000:100'])

    expect(map.dump).to eq(['0:100000:65536', '1000:201000:100'])
  end

  it 'exports the same representation as dump' do
    map = described_class.load(['0:100000:65536'])

    expect(map.export).to eq(map.dump)
  end
end
