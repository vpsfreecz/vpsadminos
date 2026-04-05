# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::ImageList do
  it 'builds an Image object for each configured image name' do
    allow(OsCtl::Image::Operations::Config::ParseList).to receive(:run)
      .and_return(%w[alpine debian])

    list = described_class.new('/build-scripts')

    expect(list.map(&:name)).to eq(%w[alpine debian])
    expect(list).to all(be_a(OsCtl::Image::Image))
  end
end
