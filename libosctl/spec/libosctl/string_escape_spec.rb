# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/string_escape'

RSpec.describe OsCtl::Lib::StringEscape do
  it 'escapes the root path' do
    expect(described_class.escape_path('/')).to eq('-')
    expect(described_class.unescape_path('-')).to eq('/')
  end

  it 'strips leading slashes and replaces path separators with dashes' do
    expect(described_class.escape_path('/var/lib')).to eq('var-lib')
  end

  it 'escapes non-allowed bytes and round-trips through unescape_path' do
    escaped = described_class.escape_path('/a b/#')

    expect(escaped).to eq('a\\x20b-\\x23')
    expect(described_class.unescape_path(escaped)).to eq('/a b/#')
  end
end
