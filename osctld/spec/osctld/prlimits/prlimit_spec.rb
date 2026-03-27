# frozen_string_literal: true

require 'osctld/prlimits/prlimit'

RSpec.describe OsCtld::PrLimits::PrLimit do
  it 'loads, updates, exports, and dumps prlimits' do
    prlimit = described_class.load('nofile', 'soft' => 1024, 'hard' => 2048)

    expect(prlimit.name).to eq('nofile')
    expect(prlimit.export).to eq(soft: 1024, hard: 2048)
    expect(prlimit.dump).to eq('soft' => 1024, 'hard' => 2048)

    prlimit.set(4096, 8192)

    expect(prlimit.export).to eq(soft: 4096, hard: 8192)
  end
end
