# frozen_string_literal: true

require 'osctld/user_control/command'
require 'osctld/user_control/commands/veth_up'
require 'osctld/user_control/commands/veth_down'
require 'osctld/utils/switch_user'
require 'osctld/container'
require 'osctld/container/lifecycle'
require 'osctld/container/run_id'
require 'osctld/utils/ip'
require 'osctld/net_interface/veth'

RSpec.describe OsCtld::UserControl::Commands::VethUp do
  let(:user) { Struct.new(:ugid).new(12_345) }
  let(:run_id) do
    OsCtld::Container::RunId.new(
      pool_name: 'tank',
      container_id: 'ct1',
      key: 'a' * 32
    )
  end
  let(:lifecycle) do
    instance_double(
      OsCtld::Container::Lifecycle,
      runs: {
        run_id.to_s => {
          'id' => run_id.dump,
          'resources' => { 'cgroup_root' => '/osctl/ct.ct1' }
        }
      },
      active_run_id: run_id,
      adopted_legacy_callback_run_id: run_id,
      reserve_callback: 'callback-1',
      activate_callback: 'callback-1',
      finish_callback: false,
      record_network_interface: true
    )
  end
  let(:netif) do
    instance_double(
      OsCtld::NetInterface::Veth,
      name: 'eth0',
      type: :routed,
      enable: true,
      up: nil,
      down: nil
    )
  end
  let(:ct) do
    instance_double(
      OsCtld::Container,
      user:,
      lifecycle:,
      base_cgroup_path: '/osctl/ct.ct1',
      netifs: { 'eth0' => netif }
    )
  end

  before do
    stub_daemon
    allow(OsCtl::Lib::Logger).to receive(:log)
    containers = stub_const('OsCtld::DB::Containers', Class.new do
      def self.find(_id, _pool); end
    end)
    allow(containers).to receive(:find).with('ct1', 'tank').and_return(ct)
    allow(OsCtld::Hook).to receive(:run)
  end

  it 'publishes the veth through its exact callback lease' do
    result = described_class.run(
      user,
      id: 'ct1',
      pool: 'tank',
      run_id: run_id.to_s,
      interface: 'eth0',
      veth: 'veth123'
    )

    expect(result).to eq(status: true, output: nil)
    expect(lifecycle).to have_received(:record_network_interface).with(
      run_id,
      name: 'eth0',
      type: :routed,
      veth: 'veth123',
      routes: {},
      callback_id: 'callback-1'
    )
    expect(netif).to have_received(:up).with('veth123')
    expect(netif).not_to have_received(:down)
  end

  it 'rolls back a veth rejected by the recovery fence' do
    allow(lifecycle).to receive(:record_network_interface).and_return(false)

    result = described_class.run(
      user,
      id: 'ct1',
      pool: 'tank',
      run_id: run_id.to_s,
      interface: 'eth0',
      veth: 'veth123'
    )

    expect(result).to eq(
      status: false,
      message: 'managed lifecycle run changed'
    )
    expect(netif).to have_received(:up).with('veth123')
    expect(netif).to have_received(:down).with('veth123')
    expect(OsCtld::Hook).not_to have_received(:run)
  end

  it 'holds an adopted veth-up callback lease across network mutation' do
    mutation_started = Queue.new
    finish_mutation = Queue.new
    allow(netif).to receive(:up) do
      mutation_started << true
      finish_mutation.pop
    end

    callback = Thread.new do
      described_class.run(
        user,
        id: 'ct1',
        pool: 'tank',
        interface: 'eth0',
        veth: 'veth123'
      )
    end
    mutation_started.pop

    expect(lifecycle).to have_received(:reserve_callback).with(
      run_id.to_s,
      name: 'VethUp'
    )
    expect(lifecycle).to have_received(:activate_callback).with(
      run_id.to_s,
      'callback-1',
      name: 'VethUp'
    )
    expect(lifecycle).not_to have_received(:finish_callback)

    finish_mutation << true

    expect(callback.value).to eq(status: true, output: nil)
    expect(lifecycle).to have_received(:finish_callback).with(
      run_id.to_s,
      'callback-1'
    )
  end

  it 'leases an id-less adopted veth-down callback' do
    result = OsCtld::UserControl::Commands::VethDown.run(
      user,
      id: 'ct1',
      pool: 'tank',
      interface: 'eth0',
      veth: 'veth123'
    )

    expect(result).to eq(status: true, output: nil)
    expect(lifecycle).to have_received(:reserve_callback).with(
      run_id.to_s,
      name: 'VethDown'
    )
    expect(lifecycle).to have_received(:activate_callback).with(
      run_id.to_s,
      'callback-1',
      name: 'VethDown'
    )
    expect(lifecycle).to have_received(:finish_callback).with(
      run_id.to_s,
      'callback-1'
    )
    expect(netif).to have_received(:down).with('veth123')
  end
end
