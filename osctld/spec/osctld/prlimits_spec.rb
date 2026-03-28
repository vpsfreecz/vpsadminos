# frozen_string_literal: true

require 'osctld/prlimits'

RSpec.describe OsCtld::PrLimits do
  it 'resolves resource constants by uppercase name' do
    stub_const('OsCtld::PrLimits::NOFILE', 1_024)

    expect(described_class.resource_to_const('nofile')).to eq(1_024)
  end
end
