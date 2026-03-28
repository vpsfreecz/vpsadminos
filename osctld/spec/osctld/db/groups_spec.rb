# frozen_string_literal: true

require 'osctld/db/groups'

RSpec.describe OsCtld::DB::Groups do
  subject(:db) { described_class.send(:new) }

  let(:pool) { Struct.new(:name, keyword_init: true).new(name: 'tank') }
  let(:group) do
    stub_const(
      'SpecDbGroup',
      Struct.new(:id, :name, :pool, keyword_init: true)
    ).new(
      id: 'default',
      name: '/default',
      pool:
    )
  end

  before do
    eventd = stub_const('OsCtld::Eventd', Module.new)
    eventd.define_singleton_method(:report) { |*| nil }
    allow(OsCtld::Eventd).to receive(:report)
  end

  it 'maintains the path index when groups are added and removed' do
    db.add(group)

    expect(db.by_path(pool, '/default')).to be(group)

    db.remove(group)

    expect(db.by_path(pool, '/default')).to be_nil
  end
end
