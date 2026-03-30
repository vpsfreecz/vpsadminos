# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/index'

RSpec.describe OsCtl::Lib::Index do
  let(:index) { described_class.new { |obj| obj[:id] } }

  it 'inserts and looks up objects' do
    index << { id: 'one', value: 1 }

    expect(index['one']).to eq(id: 'one', value: 1)
    expect(index).not_to be_empty
  end

  it 'replaces objects with the same key and supports deletion' do
    index << { id: 'one', value: 1 }
    index << { id: 'one', value: 2 }

    expect(index['one']).to eq(id: 'one', value: 2)
    expect(index.delete(id: 'one')).to eq(id: 'one', value: 2)
    expect(index).to be_empty

    index << { id: 'two', value: 2 }
    expect(index.delete_key('two')).to eq(id: 'two', value: 2)
    expect(index).to be_empty
  end
end
