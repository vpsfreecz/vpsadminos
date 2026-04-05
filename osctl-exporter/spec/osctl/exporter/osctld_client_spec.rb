# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Exporter::OsCtldClient do
  let(:client) { instance_double(OsCtl::Client) }

  before do
    allow(OsCtl::Client).to receive(:new).and_return(client)
  end

  it 'opens, yields a connected wrapper, and closes on successful try_to_connect' do
    allow(client).to receive(:open)
    allow(client).to receive(:close)

    wrapper = described_class.new
    states = []

    wrapper.try_to_connect do |w|
      states << w.connected?
    end

    expect(states).to eq([true])
    expect(wrapper.connected?).to be(false)
    expect(client).to have_received(:open)
    expect(client).to have_received(:close)
  end

  it 'logs and yields a disconnected wrapper when open fails' do
    allow(client).to receive(:open).and_raise(Errno::ENOENT)

    wrapper = described_class.new
    allow(wrapper).to receive(:log)

    connected = nil
    expect do
      wrapper.try_to_connect { |w| connected = w.connected? }
    end.not_to raise_error

    expect(connected).to be(false)
    expect(wrapper).to have_received(:log).with(
      :warn,
      include('Unable to connect to osctld:')
    )
  end

  it 'delegates ping, status, and list commands to the osctld client' do
    allow(client).to receive(:cmd_data!).with(:self_ping).and_return('pong')
    allow(client).to receive(:cmd_data!).with(:self_status).and_return({ initialized: true })
    allow(client).to receive(:cmd_data!).with(:pool_list).and_return([:pool])
    allow(client).to receive(:cmd_data!).with(:ct_list).and_return([:ct])
    allow(client).to receive(:cmd_data!).with(:netif_list).and_return([:netif])
    allow(client).to receive(:cmd_data!).with(:cpu_scheduler_status).and_return({ enabled: true })
    allow(client).to receive(:cmd_data!).with(:cpu_scheduler_package_list).and_return([:pkg])
    allow(client).to receive(:cmd_data!).with(:self_healthcheck, all: true).and_return([:health])

    wrapper = described_class.new

    expect(wrapper.ping?).to be(true)
    expect(wrapper.status).to eq(initialized: true)
    expect(wrapper.list_pools).to eq([:pool])
    expect(wrapper.list_containers).to eq([:ct])
    expect(wrapper.list_netifs).to eq([:netif])
    expect(wrapper.cpu_scheduler_status).to eq(enabled: true)
    expect(wrapper.list_cpu_packages).to eq([:pkg])
    expect(wrapper.health_check).to eq([:health])
  end
end
