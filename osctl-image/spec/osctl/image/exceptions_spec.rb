# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::OperationError do
  it 'is a standard error' do
    expect(described_class.superclass).to eq(StandardError)
  end
end
