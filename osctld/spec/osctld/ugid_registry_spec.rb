# frozen_string_literal: true

require 'osctld/lock_registry'
require 'osctld/ugid_registry'

RSpec.describe OsCtld::UGidRegistry do
  subject(:registry) { described_class.send(:new) }

  let(:valid_id) { described_class::ID_POOL.begin }
  let(:other_valid_id) { valid_id + 1 }
  let(:out_of_range_id) { described_class::ID_POOL.end + 1 }

  it 'checks whether ids are in range' do
    expect(registry.in_range?(valid_id)).to be(true)
    expect(registry.in_range?(out_of_range_id)).to be(false)
  end

  it 'registers and removes ids in range' do
    expect(registry << valid_id).to be(registry)
    expect(registry.taken?(valid_id)).to be(true)
    expect(registry.remove(valid_id)).to eq(valid_id)
    expect(registry.taken?(valid_id)).to be(false)
  end

  it 'does not duplicate registered ids' do
    registry << valid_id
    registry << valid_id

    expect(registry.export[:allocated]).to eq([valid_id])
  end

  it 'ignores out-of-range ids' do
    registry << out_of_range_id

    expect(registry.taken?(out_of_range_id)).to be(false)
    expect(registry.export[:allocated]).to be_empty
  end

  it 'raises when removing an unregistered in-range id' do
    expect { registry.remove(other_valid_id) }.to raise_error(ArgumentError, /is not registered/)
  end

  it 'exports detached copies' do
    registry << valid_id

    exported = registry.export
    exported[:allocated] << other_valid_id
    exported[:free].shift

    expect(registry.export[:allocated]).to eq([valid_id])
    expect(registry.export[:free].first).to eq(other_valid_id)
  end
end
