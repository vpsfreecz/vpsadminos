# frozen_string_literal: true

require 'osctld/db/id_ranges'

RSpec.describe OsCtld::DB::IdRanges do
  let(:pool) { Struct.new(:name, keyword_init: true).new(name: 'tank') }

  it 'loads the default range when it exists' do
    range = Object.new

    stub_const('OsCtld::IdRange', Class.new do
      def initialize(*); end
    end)
    allow(OsCtld::IdRange).to receive(:new).with(pool, 'default').and_return(range)
    allow(described_class).to receive(:add)

    described_class.setup(pool)

    expect(described_class).to have_received(:add).with(range)
  end

  it 'creates the default range when it is missing' do
    stub_const('OsCtld::IdRange', Class.new do
      def initialize(*)
        raise Errno::ENOENT
      end
    end)
    stub_const('OsCtld::Commands::IdRange::Create', Class.new do
      def self.run!(**); end
    end)
    allow(OsCtld::Commands::IdRange::Create).to receive(:run!)

    described_class.setup(pool)

    expect(OsCtld::Commands::IdRange::Create).to have_received(:run!).with(
      pool:,
      name: 'default',
      start_id: 1_000_000,
      block_size: 65_536,
      block_count: ((2**32) - 1_000_000) / 65_536
    )
  end
end
