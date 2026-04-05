# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::Test do
  it 'returns its name from #to_s' do
    test_case = described_class.new('/build-scripts', 'smoke')

    expect(test_case.to_s).to eq('smoke')
  end
end
