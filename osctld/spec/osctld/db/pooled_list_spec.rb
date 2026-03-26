# frozen_string_literal: true

require 'osctld/db/list'
require 'osctld/db/object_id'
require 'osctld/db/pooled_list'

RSpec.describe OsCtld::DB::PooledList do
  subject(:list) { klass.instance }

  let(:klass) { Class.new(described_class) }
  let(:eventd) do
    Class.new do
      def self.report(*); end
    end
  end

  before do
    stub_const(
      'OsCtld::Pool',
      Class.new do
        attr_reader :name

        def initialize(name)
          @name = name
        end
      end
    )

    stub_const('OsCtld::Eventd', eventd)
    allow(OsCtld::Eventd).to receive(:report)

    tank_pool = FakeObjects::FakeNamed.new('tank')
    other_pool = FakeObjects::FakeNamed.new('pool2')

    list.add(FakeObjects::FakeDbObject.new(id: '100', pool: tank_pool))
    list.add(FakeObjects::FakeDbObject.new(id: '100', pool: other_pool))
    list.add(FakeObjects::FakeDbObject.new(id: '101', pool: tank_pool))
  end

  it 'finds objects by id with a separate pool argument' do
    expect(list.find('100', 'tank')).to have_attributes(id: '100', pool: have_attributes(name: 'tank'))
    expect(list.find('100', 'pool2')).to have_attributes(id: '100', pool: have_attributes(name: 'pool2'))
  end

  it 'finds objects by inline pool name' do
    expect(list.find('tank:100')).to have_attributes(id: '100', pool: have_attributes(name: 'tank'))
    expect(list.find('pool2:100')).to have_attributes(id: '100', pool: have_attributes(name: 'pool2'))
  end

  it 'checks inclusion by id and pool' do
    expect(list.contains?('100', 'tank')).to be(true)
    expect(list.contains?('999', 'tank')).to be(false)
  end

  it 'selects matching ids or all objects when ids are nil' do
    expect(list.select_by_ids(%w[100 101], 'tank').map { |obj| [obj.pool.name, obj.id] }).to eq(
      [%w[tank 100], %w[tank 101]]
    )
    expect(list.select_by_ids(nil, 'tank').map { |obj| [obj.pool.name, obj.id] }).to eq(
      [%w[tank 100], %w[pool2 100], %w[tank 101]]
    )
  end

  it 'iterates matching ids with each_by_ids' do
    seen = []

    list.each_by_ids(%w[100 101], 'tank') { |obj| seen << obj }

    expect(seen.map { |obj| [obj.pool.name, obj.id] }).to eq([%w[tank 100], %w[tank 101]])
  end
end
