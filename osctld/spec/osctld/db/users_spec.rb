# frozen_string_literal: true

require 'osctld/db/users'

RSpec.describe OsCtld::DB::Users do
  subject(:db) { described_class.send(:new) }

  let(:pool) { Struct.new(:name, keyword_init: true).new(name: 'tank') }
  let(:user_class) do
    stub_const(
      'SpecDbUser',
      Struct.new(:id, :name, :pool, :ugid, :sysusername, keyword_init: true)
    )
  end
  let(:user) do
    user_class.new(
      id: 'alice',
      name: 'alice',
      pool:,
      ugid: 12_345,
      sysusername: 'u-alice'
    )
  end

  before do
    eventd = stub_const('OsCtld::Eventd', Module.new)
    eventd.define_singleton_method(:report) { |*| nil }
    registry = stub_const('OsCtld::UGidRegistry', Module.new)
    registry.define_singleton_method(:<<) { |_uid| nil }
    registry.define_singleton_method(:remove) { |_uid| nil }
    system_users = stub_const('OsCtld::SystemUsers', Module.new)
    system_users.define_singleton_method(:include?) { |_name| false }
    allow(OsCtld::Eventd).to receive(:report)
    allow(OsCtld::UGidRegistry).to receive(:<<)
    allow(OsCtld::UGidRegistry).to receive(:remove)
    allow(OsCtld::SystemUsers).to receive(:include?).and_return(false)
  end

  it 'adds users to both the list and the ugid index' do
    db.add(user)

    expect(db.by_ugid(12_345)).to be(user)
    expect(OsCtld::UGidRegistry).to have_received(:<<).with(12_345)
  end

  it 'removes ugids only when the system user is not retained' do
    db.add(user)
    db.remove(user)

    expect(db.by_ugid(12_345)).to be_nil
    expect(OsCtld::UGidRegistry).to have_received(:remove).with(12_345)
  end
end
