# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::TestList do
  it 'builds a Test object for each configured test name' do
    allow(OsCtl::Image::Operations::Config::ParseList).to receive(:run)
      .and_return(%w[smoke upgrade])

    list = described_class.new('/build-scripts')

    expect(list.map(&:name)).to eq(%w[smoke upgrade])
    expect(list).to all(be_a(OsCtl::Image::Test))
  end
end
