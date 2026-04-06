# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsVm::MacAddressGenerator do
  it 'generates mac addresses with the configured prefix' do
    expect(described_class.next_mac).to start_with('52:54:00:')
  end

  it 'generates unique mac addresses' do
    first = described_class.next_mac
    second = described_class.next_mac

    expect(first).not_to eq(second)
  end

  it 'registers and returns explicit mac addresses' do
    expect(described_class.register_mac('52:54:00:aa:bb:cc')).to eq('52:54:00:aa:bb:cc')
  end

  it 'rejects duplicate explicit mac registrations' do
    described_class.register_mac('52:54:00:aa:bb:cc')

    expect do
      described_class.register_mac('52:54:00:aa:bb:cc')
    end.to raise_error(ArgumentError, /duplicate MAC address/)
  end
end
