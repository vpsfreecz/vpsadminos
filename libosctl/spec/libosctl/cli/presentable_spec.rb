# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'libosctl/cli/presentable'

RSpec.describe OsCtl::Lib::Cli::Presentable do
  it 'formats values with explicit strings or a presenter and exposes exported values' do
    formatted = described_class.new(1024, formatted: '1K', exported: '1024')
    presented = described_class.new(2.5, presenter: ->(v) { format('%.1f units', v) })

    expect(formatted.to_s).to eq('1K')
    expect(formatted.exported).to eq('1024')
    expect(presented.to_s).to eq('2.5 units')
  end

  it 'supports numeric operators, comparisons, and coercion' do
    left = described_class.new(5, formatted: 'five')
    right = described_class.new(2, formatted: 'two')

    expect(left + right).to eq(7)
    expect(left - 1).to eq(4)
    expect(left * 2).to eq(10)
    expect(left / right).to eq(2)
    expect(left > right).to be(true)
    expect(left <=> 5).to eq(0)
    expect(1 + right).to eq(3)
  end

  it 'serializes the exported value to JSON and forwards round to the raw value' do
    value = described_class.new(1.234, formatted: '1.2', exported: 1234)

    expect(value.to_json).to eq('1234')
    expect(value.round(2)).to eq(1.23)
  end
end
