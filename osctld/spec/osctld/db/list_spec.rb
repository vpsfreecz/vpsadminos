# frozen_string_literal: true

require 'osctld/db/list'

RSpec.describe OsCtld::DB::List do
  subject(:list) { klass.instance }

  let(:klass) { Class.new(described_class) }
  let(:entry_class) { stub_const('SpecListEntry', Struct.new(:id, :pool)) }
  let(:pool) { FakeObjects::FakeNamed.new('tank') }
  let(:first_entry) { entry_class.new('100', pool) }
  let(:second_entry) { entry_class.new('101', pool) }

  before do
    eventd = Class.new do
      def self.report(*); end
    end

    stub_const('OsCtld::Eventd', eventd)
    allow(OsCtld::Eventd).to receive(:report)
  end

  it 'adds, removes, finds, checks inclusion, and counts objects' do
    list.add(first_entry)
    list.add(second_entry)

    expect(list.find('100')).to eq(first_entry)
    expect(list.contains?('101')).to be(true)
    expect(list.count).to eq(2)

    list.remove(first_entry)

    expect(list.find('100')).to be_nil
    expect(list.contains?('100')).to be(false)
    expect(list.count).to eq(1)
  end

  it 'returns a clone from get when no block is given' do
    list.add(first_entry)

    entries = list.get
    entries.clear

    expect(list.get).to eq([first_entry])
  end

  it 'iterates over current objects with each' do
    list.add(first_entry)
    list.add(second_entry)

    expect { |block| list.each(&block) }.to yield_successive_args(first_entry, second_entry)
  end

  it 'supports re-entrant sync' do
    expect do
      list.sync do
        list.sync { list.add(first_entry) }
      end
    end.not_to raise_error

    expect(list.count).to eq(1)
  end
end
