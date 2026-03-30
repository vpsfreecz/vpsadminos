# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/exceptions'
require 'libosctl/id_map'

RSpec.describe OsCtl::Lib::IdMap do
  it 'builds mappings from strings and hashes and performs lookups' do
    string_map = described_class.from_string_list(['0:100_000:10', '20:200_000:5'])
    hash_map = described_class.from_hash_list(
      [
        { ns_id: 0, host_id: 100_000, id_count: 10 },
        { ns_id: 20, host_id: 200_000, id_count: 5 }
      ]
    )

    expect(string_map.ns_to_host(4)).to eq(100_004)
    expect(string_map.host_to_ns(200_003)).to eq(23)
    expect(string_map.include_host_id?(100_001)).to be(true)
    expect(string_map.each.map(&:to_a)).to eq([[0, 100_000, 10], [20, 200_000, 5]])
    expect(string_map.to_s).to eq('0:100000:10,20:200000:5')
    expect(string_map).to eq(hash_map)
    expect(string_map).to be_valid
  end

  it 'raises when a lookup cannot be satisfied' do
    map = described_class.from_string_list(['0:100_000:10'])

    expect do
      map.host_to_ns(999)
    end.to raise_error(OsCtl::Lib::Exceptions::IdMappingError)
  end

  it 'rejects maps that cannot map root or contain negative values' do
    expect(described_class.from_string_list(['1:100_000:10'])).not_to be_valid
    expect(
      described_class.from_hash_list([{ ns_id: -1, host_id: 100_000, id_count: 10 }])
    ).not_to be_valid
  end
end
