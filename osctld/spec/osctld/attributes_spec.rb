# frozen_string_literal: true

require 'osctld/lock_registry'
require 'osctld/attributes'

RSpec.describe OsCtld::Attributes do
  subject(:attrs) { described_class.new }

  describe '.load' do
    it 'loads attributes from string keys' do
      loaded = described_class.load(
        'org.vpsadminos:color' => 'blue',
        'org.vpsadminos:size' => 'large'
      )

      expect(loaded.dump).to eq(
        'org.vpsadminos:color' => 'blue',
        'org.vpsadminos:size' => 'large'
      )
    end
  end

  it 'supports string and symbol names with set and [] access' do
    attrs.set('org.vpsadminos:color', 'blue')
    attrs[:'org.vpsadminos:size'] = 'large'

    expect(attrs['org.vpsadminos:color']).to eq('blue')
    expect(attrs[:'org.vpsadminos:size']).to eq('large')
  end

  it 'raises on invalid attribute names' do
    expect { attrs.set(:missing_namespace, 'value') }.to raise_error(RuntimeError, 'invalid attribute name')
  end

  it 'unsets attributes' do
    attrs.set(:'org.vpsadminos:color', 'blue')
    attrs.unset('org.vpsadminos:color')

    expect(attrs[:'org.vpsadminos:color']).to be_nil
  end

  it 'updates multiple values at once' do
    attrs.update(
      'org.vpsadminos:color' => 'blue',
      :'org.vpsadminos:size' => 'large'
    )

    expect(attrs.export).to eq(
      'org.vpsadminos:color': 'blue',
      'org.vpsadminos:size': 'large'
    )
  end

  it 'returns detached hashes from dump and export' do
    attrs.set(:'org.vpsadminos:color', 'blue')

    dumped = attrs.dump
    exported = attrs.export

    dumped['org.vpsadminos:color'] = 'red'
    exported[:'org.vpsadminos:color'] = 'green'

    expect(attrs.dump).to eq('org.vpsadminos:color' => 'blue')
    expect(attrs.export).to eq('org.vpsadminos:color': 'blue')
  end
end
