# frozen_string_literal: true

require 'osctld/net_interface'

RSpec.describe OsCtld::NetInterface do
  before do
    described_class.instance_variable_set(:@types, {})
  end

  after do
    described_class.instance_variable_set(:@types, nil)
  end

  it 'registers interface types and runs setup on all of them' do
    bridge = Class.new do
      def self.setup; end
    end
    routed = Class.new do
      def self.setup; end
    end

    allow(bridge).to receive(:setup)
    allow(routed).to receive(:setup)

    described_class.register(:bridge, bridge)
    described_class.register(:routed, routed)

    expect(described_class.for(:bridge)).to be(bridge)
    expect(described_class.for(:routed)).to be(routed)

    described_class.setup

    expect(bridge).to have_received(:setup).once
    expect(routed).to have_received(:setup).once
  end
end
