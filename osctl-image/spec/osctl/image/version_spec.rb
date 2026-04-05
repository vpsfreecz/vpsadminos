# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'OsCtl::Image::VERSION' do
  it 'defines a version string' do
    expect(OsCtl::Image::VERSION).to match(/\A\d{2}\.\d{2}\.\d+\z/)
  end
end
