# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/hostname'

RSpec.describe OsCtl::Lib::Hostname do
  it 'splits an FQDN into local and domain parts' do
    hostname = described_class.new('node.example.test')

    expect(hostname.local).to eq('node')
    expect(hostname.domain).to eq('example.test')
    expect(hostname.fqdn).to eq('node.example.test')
    expect(hostname.to_s).to eq('node.example.test')
  end

  it 'keeps the domain empty for single-label hostnames' do
    hostname = described_class.new('node')

    expect(hostname.local).to eq('node')
    expect(hostname.domain).to eq('')
  end
end
