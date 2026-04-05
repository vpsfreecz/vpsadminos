# frozen_string_literal: true

require 'spec_helper'
require 'vpsadminos-converter/auto_start'

RSpec.describe VpsAdminOS::Converter::AutoStart do
  subject(:auto_start) { described_class.new }

  it 'uses the expected defaults' do
    expect(auto_start.enabled).to be(false)
    expect(auto_start.priority).to eq(10)
    expect(auto_start.delay).to eq(5)
  end

  it 'returns nil from dump while disabled' do
    expect(auto_start.dump).to be_nil
  end

  it 'dumps the enabled configuration' do
    auto_start.enabled = true
    auto_start.priority = 20
    auto_start.delay = 8

    expect(auto_start.dump).to eq(
      'priority' => 20,
      'delay' => 8
    )
  end
end
