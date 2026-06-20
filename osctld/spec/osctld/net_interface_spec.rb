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

  it 'serializes host-link registry users and permits owner re-entry' do
    holder_ready = Queue.new
    release_holder = Queue.new
    waiter_ready = Queue.new
    events = Queue.new

    holder = Thread.new do
      described_class.sync_host_link_registry do
        described_class.sync_host_link_registry { events << :reentered }
        holder_ready << true
        release_holder.pop
      end
    end
    holder_ready.pop

    waiter = Thread.new do
      waiter_ready << true
      described_class.sync_host_link_registry { events << :waiter }
    end
    waiter_ready.pop

    expect(events.pop).to eq(:reentered)
    expect(waiter.join(0.05)).to be_nil

    release_holder << true
    holder.join
    waiter.join

    expect(events.pop).to eq(:waiter)
  ensure
    release_holder << true if holder&.alive?
    holder&.join
    waiter&.join
  end
end
