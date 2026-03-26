# frozen_string_literal: true

require 'osctld/db/object_id'

RSpec.describe OsCtld::DB::ObjectId do
  let(:pool_class) do
    Class.new do
      attr_reader :name

      def initialize(name)
        @name = name
      end
    end
  end

  let(:pool) { pool_class.new('tank') }
  let(:obj) { FakeObjects::FakeDbObject.new(id: '100', pool: FakeObjects::FakeNamed.new('tank')) }

  before do
    stub_const('OsCtld::Pool', pool_class)
  end

  it 'parses pool-qualified ids' do
    object_id = described_class.new('tank:100')

    expect(object_id.pool).to eq('tank')
    expect(object_id.id).to eq('100')
  end

  it 'uses the separate pool argument when no inline pool is present' do
    object_id = described_class.new('100', pool)

    expect(object_id.pool).to eq('tank')
    expect(object_id.id).to eq('100')
  end

  it 'prefers the inline pool over the separate pool argument' do
    object_id = described_class.new('tank:100', 'other')

    expect(object_id.pool).to eq('tank')
  end

  it 'matches objects against arrays of pools' do
    object_id = described_class.new('100', %w[tank pool2])

    expect(object_id.match?(obj)).to be(true)
  end

  it 'raises on invalid pool types' do
    expect { described_class.new('100', 1) }.to raise_error(RuntimeError, /invalid pool type/)
  end

  it 'matches objects by pool and id' do
    expect(described_class.new('100', 'tank').match?(obj)).to be(true)
    expect(described_class.new('100', 'pool2').match?(obj)).to be(false)
    expect(described_class.new('tank:999').match?(obj)).to be(false)
  end
end
