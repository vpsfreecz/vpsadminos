# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TestRunner::ExampleConfiguration do
  it 'defaults to random ordering' do
    expect(described_class.new.default_order).to eq(:rand)
  end

  it 'allows overriding the default order' do
    config = described_class.new
    config.default_order = :defined

    expect(config.default_order).to eq(:defined)
  end
end
