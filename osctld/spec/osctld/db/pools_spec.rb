# frozen_string_literal: true

require 'osctld/db/pools'

RSpec.describe OsCtld::DB::Pools do
  subject(:db) { described_class.send(:new) }

  before do
    db.instance_variable_set(
      '@objects',
      [
        Struct.new(:id, :name, keyword_init: true).new(id: 'tank', name: 'tank'),
        Struct.new(:id, :name, keyword_init: true).new(id: 'pool2', name: 'pool2')
      ]
    )
  end

  it 'returns the requested pool or the first pool as default' do
    expect(db.get_or_default('pool2').name).to eq('pool2')
    expect(db.get_or_default(nil).name).to eq('tank')
  end
end
